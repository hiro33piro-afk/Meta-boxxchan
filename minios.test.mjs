// Boots images/minios.img in v86 (headless, Node.js) and drives the MiniOS
// shell through the COM1 serial console.

import { test, before, after } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const require = createRequire(import.meta.url);
const { V86 } = require(join(ROOT, "vendor/v86/libv86.js"));

const file = (path) => {
    const data = readFileSync(join(ROOT, path));
    return { buffer: data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength) };
};

let emulator;
let serial = "";

function waitFor(pattern, timeout = 20000) {
    return new Promise((resolve, reject) => {
        const start = Date.now();
        const check = () => {
            const match = serial.match(pattern);
            if (match) return resolve(match);
            if (Date.now() - start > timeout) {
                return reject(new Error(`Timed out waiting for ${pattern}. Serial output:\n${serial}`));
            }
            setTimeout(check, 50);
        };
        check();
    });
}

async function run(command) {
    serial = "";
    emulator.serial0_send(command + "\r");
    await waitFor(/minios> $/);
    return serial;
}

before(async () => {
    emulator = new V86({
        wasm_path: join(ROOT, "vendor/v86/v86.wasm"),
        bios: file("vendor/bios/seabios.bin"),
        vga_bios: file("vendor/bios/vgabios.bin"),
        fda: file("images/minios.img"),
        memory_size: 32 * 1024 * 1024,
        autostart: true,
        disable_keyboard: true,
        disable_mouse: true,
        disable_speaker: true,
    });
    emulator.add_listener("serial0-output-byte", (byte) => {
        serial += String.fromCharCode(byte);
    });
    await waitFor(/minios> $/, 60000);
});

after(async () => {
    await emulator?.destroy();
});

test("boots to the shell", () => {
    assert.match(serial, /MiniOS 1\.0/);
});

test("help lists commands", async () => {
    const out = await run("help");
    for (const cmd of ["cpu", "mem", "calc", "ls", "gfx", "reboot"]) {
        assert.match(out, new RegExp(`\\b${cmd}\\b`));
    }
});

test("echo", async () => {
    assert.match(await run("echo Hello VM"), /Hello VM\r\n/);
});

test("calc", async () => {
    assert.match(await run("calc 6 * 7"), /= 42/);
    assert.match(await run("calc 10 - 25"), /= -15/);
    assert.match(await run("calc 17 % 5"), /= 2/);
    assert.match(await run("calc 1 / 0"), /Division by zero/);
});

test("mem reports the configured RAM", async () => {
    assert.match(await run("mem"), /Total:\s+32 MB/);
});

test("cpu shows CPUID info", async () => {
    assert.match(await run("cpu"), /Vendor:\s+\S+/);
});

test("time and date", async () => {
    assert.match(await run("time"), /Time: \d\d:\d\d:\d\d/);
    assert.match(await run("date"), /Date: \d{4}-\d\d-\d\d/);
});

test("file system: ls, cat, write, rm", async () => {
    assert.match(await run("ls"), /readme\.txt/);
    assert.match(await run("cat hello.txt"), /Hello, world!/);
    await run("write notes.txt first line");
    await run("write notes.txt second line");
    assert.match(await run("cat notes.txt"), /first line\r\nsecond line/);
    assert.match(await run("ls"), /notes\.txt\s+23 bytes/);
    await run("rm notes.txt");
    assert.match(await run("cat notes.txt"), /File not found/);
});

test("unknown command", async () => {
    assert.match(await run("foo"), /Unknown command: foo/);
});

test("history recalls the previous command", async () => {
    await run("echo again");
    assert.match(await run("\x1b[A"), /again\r\nagain/);
});

test("gfx demo switches to 320x200 and back", async () => {
    let size;
    emulator.add_listener("screen-set-size", (s) => { size = s; });
    serial = "";
    emulator.serial0_send("gfx\r");
    await new Promise((resolve) => setTimeout(resolve, 1500));
    assert.deepEqual(size?.slice(0, 2), [320, 200]);
    emulator.serial0_send("q");
    await waitFor(/Back in text mode/);
    await waitFor(/minios> $/);
});

test("files survive a reboot", async () => {
    await run("write keep.txt persisted");
    serial = "";
    emulator.serial0_send("reboot\r");
    await waitFor(/Rebooting/);
    await waitFor(/MiniOS 1\.0[\s\S]*minios> $/, 60000);
    assert.match(await run("cat keep.txt"), /persisted/);
});
