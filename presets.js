// OS images that can be booted with one click.
//
// MiniOS ships with this repository. The others are downloaded on demand
// from the public image mirrors used by the v86 project (copy.sh).

const MIRROR = "https://i.copy.sh/";

export const PRESETS = [
    {
        id: "minios",
        name: "MiniOS",
        description: "このリポジトリ同梱の自作 16bit OS。シェル・ファイル・グラフィックス",
        size: "1.4 MB",
        bundled: true,
        memory: 32,
        fda: { url: "images/minios.img", size: 1474560 },
    },
    {
        id: "freedos",
        name: "FreeDOS",
        description: "MS-DOS 互換のフリーな DOS",
        size: "720 KB",
        memory: 32,
        fda: { url: MIRROR + "freedos722.img", size: 737280 },
    },
    {
        id: "kolibrios",
        name: "KolibriOS",
        description: "フロッピー 1 枚に収まる GUI OS",
        size: "1.4 MB",
        memory: 128,
        fda: { url: "https://builds.kolibrios.org/en_US/data/data/kolibri.img", size: 1474560 },
    },
    {
        id: "linux",
        name: "Linux",
        description: "CD-ROM から起動する軽量 Linux",
        size: "7.4 MB",
        memory: 64,
        cdrom: { url: MIRROR + "linux4.iso", size: 7731200 },
        filesystem: {},
    },
    {
        id: "buildroot",
        name: "Buildroot Linux",
        description: "Linux カーネルを直接起動 (bzImage)",
        size: "4.9 MB",
        memory: 64,
        bzimage: { url: MIRROR + "buildroot-bzimage.bin", size: 5166352 },
        cmdline: "tsc=reliable mitigations=off random.trust_cpu=on",
        filesystem: {},
    },
    {
        id: "tinycore",
        name: "Tiny Core Linux",
        description: "デスクトップ付きの小さな Linux",
        size: "19 MB",
        memory: 256,
        hda: { url: MIRROR + "TinyCore-11.0.iso", size: 19922944 },
    },
];
