import { PRESETS } from "./presets.js";

const V86 = window.V86;

const FLOPPY_SIZES = new Set([163840, 184320, 327680, 368640, 737280, 1228800, 1474560, 1720320, 2949120]);
const MB = 1024 * 1024;
const SERIAL_LIMIT = 100000;

const $ = (id) => document.getElementById(id);

const ui = {
    osList: $("os-list"),
    screen: $("screen"),
    screenWrap: $("screen-wrap"),
    overlay: $("overlay"),
    welcome: $("welcome"),
    loading: $("loading"),
    loadingText: $("loading-text"),
    progressBar: $("progress-bar"),
    status: $("status"),
    statusText: $("status-text"),
    statSpeed: $("stat-speed"),
    statTime: $("stat-time"),
    fileInput: $("file-input"),
    dropzone: $("dropzone"),
    customUrl: $("custom-url"),
    customType: $("custom-type"),
    memory: $("memory"),
    vgaMemory: $("vga-memory"),
    acpi: $("acpi"),
    speaker: $("speaker"),
    scale: $("scale"),
    stateInput: $("state-input"),
    serialPanel: $("serial-panel"),
    serialOutput: $("serial-output"),
    serialForm: $("serial-form"),
    serialInput: $("serial-input"),
    toast: $("toast"),
    buttons: {
        pause: $("btn-pause"),
        reset: $("btn-reset"),
        stop: $("btn-stop"),
        cad: $("btn-cad"),
        mouse: $("btn-mouse"),
        fullscreen: $("btn-fullscreen"),
        screenshot: $("btn-screenshot"),
        save: $("btn-save"),
        restore: $("btn-restore"),
    },
};

let emulator = null;
let current = null;        // { name, id }
let bootToken = 0;         // invalidates events from destroyed emulators
let running = false;
let uptimeMs = 0;
let lastTick = 0;
let lastInstructions = 0;
let statsTimer = null;

// ---------------------------------------------------------------------------
// OS list
// ---------------------------------------------------------------------------

function renderPresets() {
    for (const preset of PRESETS) {
        const button = document.createElement("button");
        button.className = "os-card";
        button.dataset.id = preset.id;
        button.innerHTML = `
            <span class="os-name"></span>
            <span class="os-desc"></span>
            <span class="os-meta"><span class="tag"></span><span class="size"></span></span>`;
        button.querySelector(".os-name").textContent = preset.name;
        button.querySelector(".os-desc").textContent = preset.description;
        button.querySelector(".tag").textContent = preset.bundled ? "同梱" : "ダウンロード";
        button.querySelector(".tag").classList.toggle("bundled", !!preset.bundled);
        button.querySelector(".size").textContent = preset.size;
        button.addEventListener("click", () => bootPreset(preset));
        ui.osList.append(button);
    }
}

function markActive(id) {
    for (const card of ui.osList.children) {
        card.classList.toggle("active", card.dataset.id === id);
    }
}

// ---------------------------------------------------------------------------
// Booting
// ---------------------------------------------------------------------------

function bootPreset(preset) {
    const disks = {};
    for (const key of ["fda", "cdrom", "hda", "bzimage"]) {
        if (preset[key]) disks[key] = { ...preset[key], async: false };
    }
    if (preset.cmdline) disks.cmdline = preset.cmdline;
    if (preset.filesystem) disks.filesystem = preset.filesystem;
    boot({ id: preset.id, name: preset.name, memory: preset.memory, disks });
    setUrlParam(preset.id);
}

function detectType(name, size) {
    const selected = ui.customType.value;
    if (selected !== "auto") return selected;
    const lower = name.toLowerCase();
    if (lower.endsWith(".iso")) return "cdrom";
    if (/bzimage|vmlinuz/.test(lower)) return "bzimage";
    if (size !== undefined && FLOPPY_SIZES.has(size)) return "fda";
    if (size === undefined && /\.(ima|vfd|flp)$/.test(lower)) return "fda";
    return "hda";
}

function bootFile(file) {
    const type = detectType(file.name, file.size);
    const disks = { [type]: { buffer: file } };
    if (type === "bzimage") disks.cmdline = "tsc=reliable mitigations=off random.trust_cpu=on";
    boot({ id: null, name: file.name, memory: 128, disks });
    setUrlParam(null);
}

function bootUrl(url) {
    let name;
    try {
        name = decodeURIComponent(new URL(url, location.href).pathname.split("/").pop()) || url;
    } catch {
        toast("URL が正しくありません");
        return;
    }
    const type = detectType(name);
    const disks = { [type]: { url, async: false } };
    boot({ id: null, name, memory: 128, disks });
    setUrlParam(null);
}

async function boot(config) {
    const token = ++bootToken;
    await shutdown({ keepOverlay: true });
    if (token !== bootToken) return;

    current = config;
    uptimeMs = 0;
    markActive(config.id);
    clearSerial();
    showLoading(`${config.name} を準備しています…`, 0);
    setStatus("loading", "読み込み中");

    const memoryMb = Number(ui.memory.value) || config.memory || 64;

    emulator = new V86({
        wasm_path: "vendor/v86/v86.wasm",
        bios: { url: "vendor/bios/seabios.bin" },
        vga_bios: { url: "vendor/bios/vgabios.bin" },
        screen_container: ui.screen,
        memory_size: memoryMb * MB,
        vga_memory_size: Number(ui.vgaMemory.value) * MB,
        acpi: ui.acpi.checked,
        disable_speaker: !ui.speaker.checked,
        autostart: true,
        ...config.disks,
    });
    window.emulator = emulator;

    const on = (event, handler) => emulator.add_listener(event, (arg) => {
        if (token === bootToken) handler(arg);
    });

    on("download-progress", (e) => {
        const name = e.file_name.split("/").pop();
        if (e.lengthComputable && e.total) {
            const ratio = e.loaded / e.total;
            showLoading(`${name} をダウンロード中… ${(e.loaded / MB).toFixed(1)} / ${(e.total / MB).toFixed(1)} MB`, ratio);
        } else {
            showLoading(`${name} をダウンロード中… ${(e.loaded / MB).toFixed(1)} MB`, null);
        }
    });

    on("download-error", (e) => {
        const name = e.file_name.split("/").pop();
        setStatus("error", "エラー");
        toast(`${name} のダウンロードに失敗しました。ネットワークや CORS 設定を確認してください。`, 8000);
        shutdown();
    });

    on("emulator-ready", () => {
        showLoading("起動中…", 1);
    });

    on("emulator-started", () => {
        running = true;
        hideOverlay();
        setStatus("running", `${config.name} 実行中`);
        setControlsEnabled(true);
        ui.buttons.pause.textContent = "⏸ 一時停止";
        ui.screen.focus();
        startStats();
    });

    on("emulator-stopped", () => {
        running = false;
        if (emulator) {
            setStatus("paused", "一時停止中");
            ui.buttons.pause.textContent = "▶ 再開";
        }
    });

    on("screen-set-size", () => requestAnimationFrame(fitScreen));
    on("serial0-output-byte", appendSerial);
}

async function shutdown({ keepOverlay = false } = {}) {
    stopStats();
    running = false;
    const old = emulator;
    emulator = null;
    window.emulator = null;
    setControlsEnabled(false);
    if (old) {
        try {
            await old.destroy();
        } catch (e) {
            console.warn("destroy failed", e);
        }
    }
    resetScreen();
    if (!keepOverlay) {
        current = null;
        markActive(null);
        setStatus("idle", "停止中");
        showWelcome();
        setUrlParam(null);
    }
}

function resetScreen() {
    const text = ui.screen.querySelector(".text-layer");
    const canvas = ui.screen.querySelector("canvas");
    text.textContent = "";
    text.style.display = "none";
    canvas.style.display = "block";
    canvas.width = 720;
    canvas.height = 400;
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height);
    fitScreen();
}

// ---------------------------------------------------------------------------
// Overlay / status
// ---------------------------------------------------------------------------

function showWelcome() {
    ui.overlay.hidden = false;
    ui.welcome.hidden = false;
    ui.loading.hidden = true;
}

function showLoading(text, ratio) {
    ui.overlay.hidden = false;
    ui.welcome.hidden = true;
    ui.loading.hidden = false;
    ui.loadingText.textContent = text;
    ui.progressBar.parentElement.classList.toggle("indeterminate", ratio === null);
    ui.progressBar.style.width = ratio === null ? "30%" : `${Math.round(ratio * 100)}%`;
}

function hideOverlay() {
    ui.overlay.hidden = true;
}

function setStatus(state, text) {
    ui.status.dataset.state = state;
    ui.statusText.textContent = text;
}

function setControlsEnabled(enabled) {
    for (const [key, button] of Object.entries(ui.buttons)) {
        if (key === "restore") {
            button.setAttribute("aria-disabled", String(!enabled));
        } else {
            button.disabled = !enabled;
        }
    }
    if (!enabled) {
        ui.statSpeed.textContent = "–";
        ui.statTime.textContent = "–";
    }
}

let toastTimer = null;
function toast(message, duration = 4000) {
    ui.toast.textContent = message;
    ui.toast.classList.add("show");
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => ui.toast.classList.remove("show"), duration);
}

function setUrlParam(id) {
    const url = new URL(location.href);
    if (id) url.searchParams.set("os", id);
    else url.searchParams.delete("os");
    history.replaceState(null, "", url);
}

// ---------------------------------------------------------------------------
// Stats
// ---------------------------------------------------------------------------

function startStats() {
    stopStats();
    lastTick = performance.now();
    lastInstructions = emulator.get_instruction_counter();
    statsTimer = setInterval(updateStats, 1000);
}

function stopStats() {
    clearInterval(statsTimer);
    statsTimer = null;
}

function updateStats() {
    if (!emulator) return;
    const now = performance.now();
    const elapsed = now - lastTick;
    lastTick = now;
    const counter = emulator.get_instruction_counter();
    let delta = counter - lastInstructions;
    if (delta < 0) delta += 2 ** 32;
    lastInstructions = counter;
    if (!running) {
        ui.statSpeed.textContent = "0 MIPS";
        return;
    }
    uptimeMs += elapsed;
    ui.statSpeed.textContent = `${(delta / elapsed / 1000).toFixed(1)} MIPS`;
    const seconds = Math.floor(uptimeMs / 1000);
    const h = Math.floor(seconds / 3600);
    const m = Math.floor(seconds / 60) % 60;
    const s = seconds % 60;
    ui.statTime.textContent = (h ? `${h}:` : "") + `${String(m).padStart(h ? 2 : 1, "0")}:${String(s).padStart(2, "0")}`;
}

// ---------------------------------------------------------------------------
// Screen scaling
// ---------------------------------------------------------------------------

function fitScreen() {
    // Layout size of the emulator output (transforms do not affect offsetWidth).
    const width = ui.screen.offsetWidth || 720;
    const height = ui.screen.offsetHeight || 400;

    const fullscreen = document.fullscreenElement === ui.screenWrap;
    const availableWidth = ui.screenWrap.clientWidth;
    const availableHeight = fullscreen ? ui.screenWrap.clientHeight : Infinity;

    let scale;
    if (ui.scale.value === "auto") {
        scale = Math.min(availableWidth / width, availableHeight / height, fullscreen ? Infinity : 2);
        // Snap to half steps when upscaling (sharper pixels), except in fullscreen.
        if (!fullscreen && scale > 1) scale = Math.max(1, Math.floor(scale * 2) / 2);
    } else {
        scale = Number(ui.scale.value);
    }

    ui.screen.style.transform = `scale(${scale})`;
    ui.screenWrap.style.height = fullscreen ? "" : `${Math.max(height * scale, 240)}px`;
}

// ---------------------------------------------------------------------------
// Serial console
// ---------------------------------------------------------------------------

let serialBuffer = "";
let serialFlush = 0;
let ansiState = 0;

function appendSerial(byte) {
    // Strip ANSI escape sequences (ESC [ ... letter).
    if (ansiState === 1) {
        ansiState = byte === 0x5B ? 2 : 0;
        return;
    }
    if (ansiState === 2) {
        if (byte >= 0x40 && byte <= 0x7E) ansiState = 0;
        return;
    }
    if (byte === 0x1B) {
        ansiState = 1;
        return;
    }
    if (byte === 0x0D || byte === 0x07) return;
    if (byte === 0x08) {
        serialBuffer += "\b";
    } else {
        serialBuffer += String.fromCharCode(byte);
    }
    if (!serialFlush) serialFlush = requestAnimationFrame(flushSerial);
}

function flushSerial() {
    serialFlush = 0;
    let text = ui.serialOutput.textContent;
    for (const ch of serialBuffer) {
        text = ch === "\b" ? text.slice(0, -1) : text + ch;
    }
    serialBuffer = "";
    if (text.length > SERIAL_LIMIT) text = text.slice(-SERIAL_LIMIT);
    const atBottom = ui.serialOutput.scrollTop + ui.serialOutput.clientHeight >= ui.serialOutput.scrollHeight - 4;
    ui.serialOutput.textContent = text;
    if (atBottom) ui.serialOutput.scrollTop = ui.serialOutput.scrollHeight;
}

function clearSerial() {
    serialBuffer = "";
    ansiState = 0;
    ui.serialOutput.textContent = "";
}

// ---------------------------------------------------------------------------
// Controls
// ---------------------------------------------------------------------------

function download(blob, filename) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = filename;
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
}

function safeName() {
    return (current?.id || current?.name || "vm").replace(/[^\w.-]+/g, "_");
}

function bindControls() {
    $("quick-start").addEventListener("click", () => bootPreset(PRESETS[0]));

    ui.buttons.pause.addEventListener("click", async () => {
        if (!emulator) return;
        if (running) {
            await emulator.stop();
        } else {
            await emulator.run();
            setStatus("running", `${current.name} 実行中`);
            ui.buttons.pause.textContent = "⏸ 一時停止";
            ui.screen.focus();
        }
    });

    ui.buttons.reset.addEventListener("click", () => {
        if (!emulator) return;
        emulator.restart();
        uptimeMs = 0;
        toast("リセットしました");
        ui.screen.focus();
    });

    ui.buttons.stop.addEventListener("click", () => shutdown());

    ui.buttons.cad.addEventListener("click", () => {
        emulator?.keyboard_send_scancodes([
            0x1D, 0x38, 0xE0, 0x53,             // Ctrl, Alt, Delete down
            0xE0, 0xD3, 0xB8, 0x9D,             // Delete, Alt, Ctrl up
        ]);
        ui.screen.focus();
    });

    ui.buttons.mouse.addEventListener("click", () => {
        emulator?.lock_mouse();
    });

    ui.buttons.fullscreen.addEventListener("click", async () => {
        try {
            await ui.screenWrap.requestFullscreen();
            ui.screen.focus();
        } catch {
            toast("全画面表示に切り替えられませんでした");
        }
    });
    document.addEventListener("fullscreenchange", () => requestAnimationFrame(fitScreen));

    ui.buttons.screenshot.addEventListener("click", () => {
        if (!emulator) return;
        try {
            const image = emulator.screen_make_screenshot();
            const a = document.createElement("a");
            a.href = image.src;
            a.download = `${safeName()}-screenshot.png`;
            a.click();
        } catch (e) {
            console.error(e);
            toast("スクリーンショットを取得できませんでした");
        }
    });

    ui.buttons.save.addEventListener("click", async () => {
        if (!emulator) return;
        try {
            toast("状態を保存しています…");
            const state = await emulator.save_state();
            download(new Blob([state]), `${safeName()}-state.bin`);
            toast(`状態を保存しました (${(state.byteLength / MB).toFixed(1)} MB)`);
        } catch (e) {
            console.error(e);
            toast("状態の保存に失敗しました");
        }
    });

    ui.buttons.restore.addEventListener("click", (e) => {
        if (!emulator) {
            e.preventDefault();
            toast("先に OS を起動してください (同じ OS・同じメモリ設定で復元できます)");
        }
    });

    ui.stateInput.addEventListener("change", async () => {
        const file = ui.stateInput.files[0];
        ui.stateInput.value = "";
        if (!file || !emulator) return;
        try {
            await emulator.restore_state(await file.arrayBuffer());
            await emulator.run();
            toast("状態を復元しました");
            ui.screen.focus();
        } catch (e) {
            console.error(e);
            toast("復元に失敗しました。起動中の OS やメモリ設定が保存時と同じか確認してください。", 8000);
        }
    });

    ui.scale.addEventListener("change", fitScreen);
    new ResizeObserver(() => fitScreen()).observe(ui.screenWrap);

    $("btn-sidebar").addEventListener("click", () => {
        document.body.classList.toggle("sidebar-hidden");
        requestAnimationFrame(fitScreen);
    });

    ui.screen.addEventListener("mousedown", () => ui.screen.focus());

    // Custom images
    ui.fileInput.addEventListener("change", () => {
        const file = ui.fileInput.files[0];
        ui.fileInput.value = "";
        if (file) bootFile(file);
    });

    for (const target of [ui.dropzone, ui.screenWrap]) {
        target.addEventListener("dragover", (e) => {
            e.preventDefault();
            target.classList.add("dragging");
        });
        target.addEventListener("dragleave", () => target.classList.remove("dragging"));
        target.addEventListener("drop", (e) => {
            e.preventDefault();
            target.classList.remove("dragging");
            const file = e.dataTransfer.files[0];
            if (file) bootFile(file);
        });
    }

    $("url-boot").addEventListener("click", () => {
        const url = ui.customUrl.value.trim();
        if (url) bootUrl(url);
        else toast("URL を入力してください");
    });
    ui.customUrl.addEventListener("keydown", (e) => {
        if (e.key === "Enter") $("url-boot").click();
    });

    // Serial console
    ui.serialForm.addEventListener("submit", (e) => {
        e.preventDefault();
        if (!emulator) {
            toast("VM が起動していません");
            return;
        }
        emulator.serial0_send(ui.serialInput.value + "\r");
        ui.serialInput.value = "";
    });
    $("serial-clear").addEventListener("click", clearSerial);
}

// ---------------------------------------------------------------------------

function init() {
    if (!V86) {
        toast("v86 の読み込みに失敗しました", 10000);
        return;
    }
    renderPresets();
    bindControls();
    resetScreen();
    showWelcome();

    const id = new URLSearchParams(location.search).get("os");
    const preset = PRESETS.find((p) => p.id === id);
    if (preset) bootPreset(preset);
}

init();
