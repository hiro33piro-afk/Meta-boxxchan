// Builds images/minios.img: a bootable 1.44 MB floppy image containing the
// MiniOS boot sector, kernel and an initial file system with os/files/*.
//
// Requires NASM (https://www.nasm.us/) on PATH.

import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const OS_DIR = join(ROOT, "os");
const OUT = join(ROOT, "images", "minios.img");

const SECTOR = 512;
const FLOPPY_SIZE = 1474560;
const KERNEL_SECTORS = 32;
const FS_LBA = 1 + KERNEL_SECTORS;
const FS_ENTRIES = 16;
const FS_ENTRY_SIZE = 1024;
const FS_NAME_MAX = 13;
const FS_SIZE_OFF = 14;
const FS_DATA_OFF = 16;
const FS_DATA_MAX = FS_ENTRY_SIZE - FS_DATA_OFF;

function nasm(source, workDir) {
    const out = join(workDir, source.replace(/\.asm$/, ".bin"));
    execFileSync("nasm", [
        "-f", "bin",
        "-w+all",
        `-DKERNEL_SECTORS=${KERNEL_SECTORS}`,
        "-o", out,
        join(OS_DIR, source),
    ], { stdio: "inherit" });
    return readFileSync(out);
}

function buildFileSystem() {
    const fs = Buffer.alloc(FS_ENTRIES * FS_ENTRY_SIZE);
    const files = readdirSync(join(OS_DIR, "files")).sort();
    if (files.length > FS_ENTRIES) {
        throw new Error(`Too many files (max ${FS_ENTRIES})`);
    }
    files.forEach((name, i) => {
        if (name.length > FS_NAME_MAX) {
            throw new Error(`File name too long (max ${FS_NAME_MAX}): ${name}`);
        }
        const data = readFileSync(join(OS_DIR, "files", name));
        if (data.length > FS_DATA_MAX) {
            throw new Error(`File too large (max ${FS_DATA_MAX} bytes): ${name}`);
        }
        const base = i * FS_ENTRY_SIZE;
        fs.write(name, base, "ascii");
        fs.writeUInt16LE(data.length, base + FS_SIZE_OFF);
        data.copy(fs, base + FS_DATA_OFF);
    });
    return { fs, files };
}

const workDir = mkdtempSync(join(tmpdir(), "minios-"));
try {
    const boot = nasm("boot.asm", workDir);
    const kernel = nasm("kernel.asm", workDir);
    if (boot.length !== SECTOR) throw new Error("Boot sector must be 512 bytes");
    if (kernel.length !== KERNEL_SECTORS * SECTOR) throw new Error("Unexpected kernel size");

    const { fs, files } = buildFileSystem();
    const image = Buffer.alloc(FLOPPY_SIZE);
    boot.copy(image, 0);
    kernel.copy(image, SECTOR);
    fs.copy(image, FS_LBA * SECTOR);

    mkdirSync(dirname(OUT), { recursive: true });
    writeFileSync(OUT, image);
    console.log(`Wrote ${OUT} (${image.length} bytes, files: ${files.join(", ")})`);
} finally {
    rmSync(workDir, { recursive: true, force: true });
}
