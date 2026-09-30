; MiniOS kernel - a tiny 16-bit real-mode operating system.
;
; Loaded by boot.asm at 0000:8000. Features:
;   * VGA text-mode console driver (direct video memory, colors, scrolling)
;   * COM1 serial console (all output is mirrored, input is accepted)
;   * Command shell with line editing and history (Up arrow)
;   * Tiny file system persisted to the boot disk (ls/cat/write/rm)
;   * RTC clock, memory/CPU info, calculator, VGA graphics demo, PC speaker
;
; Memory map (segment 0):
;   0x0500 - 0x7BFF  stack (grows down from 0x7C00)
;   0x7C00 - 0x7DFF  boot sector
;   0x8000 - 0xBFFF  kernel (KERNEL_SECTORS * 512 bytes)
;   0xC000 - 0xFFFF  file system (FS_ENTRIES * FS_ENTRY_SIZE bytes)
;
; Disk layout (LBA):
;   0                        boot sector
;   1 .. KERNEL_SECTORS      kernel
;   FS_LBA .. FS_LBA + 31    file system (2 sectors per entry)

bits 16
org 0x8000

%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 32
%endif

FS_BASE         equ 0xC000
FS_ENTRIES      equ 16
FS_ENTRY_SIZE   equ 1024
FS_NAME_MAX     equ 13
FS_SIZE_OFF     equ 14
FS_DATA_OFF     equ 16
FS_DATA_MAX     equ FS_ENTRY_SIZE - FS_DATA_OFF
FS_LBA          equ 1 + KERNEL_SECTORS
FS_SECTORS      equ FS_ENTRIES * FS_ENTRY_SIZE / 512

COM1            equ 0x3F8
LINE_MAX        equ 76
SCREEN_COLS     equ 80
SCREEN_ROWS     equ 25

ATTR_DEFAULT    equ 0x1F    ; white on blue
ATTR_PROMPT     equ 0x1A    ; light green on blue
ATTR_TITLE      equ 0x1E    ; yellow on blue
ATTR_ERROR      equ 0x1C    ; light red on blue

BDA_TICKS       equ 0x046C
TICKS_PER_DAY   equ 1573040

; ---------------------------------------------------------------------------
; Entry point
; ---------------------------------------------------------------------------
kernel_entry:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov [boot_drive], dl

    call serial_init
    call disk_init

    xor ah, ah
    int 0x1A
    mov [boot_ticks], dx
    mov [boot_ticks + 2], cx

    mov ax, 0x0003
    int 0x10
    mov byte [cur_attr], ATTR_DEFAULT
    call cls

    mov si, str_banner
    mov bl, ATTR_TITLE
    call puts_color
    mov si, str_welcome
    call puts

    call fs_load

shell_loop:
    mov si, str_prompt
    mov bl, ATTR_PROMPT
    call puts_color
    call readline
    call execute
    jmp shell_loop

; ---------------------------------------------------------------------------
; Command dispatcher
; ---------------------------------------------------------------------------

; Execute the command in line_buf.
execute:
    mov si, line_buf
    call skip_spaces
    cmp byte [si], 0
    je .done

    mov bx, cmd_table
.next:
    mov di, [bx]
    test di, di
    jz .unknown
    call match_word
    jnc .found
    add bx, 6
    jmp .next
.found:
    call word [bx + 2]
.done:
    ret
.unknown:
    push si
    mov si, str_unknown
    mov bl, ATTR_ERROR
    call puts_color
    pop si
.copy_word:
    lodsb
    test al, al
    jz .unknown_end
    cmp al, ' '
    je .unknown_end
    call putc
    jmp .copy_word
.unknown_end:
    mov si, str_unknown2
    call puts
    ret

; Compare the word at SI with the NUL-terminated name at DI (case-insensitive).
; On match: CF=0, SI points to the arguments (leading spaces skipped).
; On mismatch: CF=1, SI unchanged.
match_word:
    push si
    push di
.loop:
    mov al, [si]
    call to_lower
    mov ah, [di]
    test ah, ah
    jz .name_end
    cmp al, ah
    jne .fail
    inc si
    inc di
    jmp .loop
.name_end:
    test al, al
    jz .ok
    cmp al, ' '
    je .ok
.fail:
    pop di
    pop si
    stc
    ret
.ok:
    pop di
    add sp, 2
    call skip_spaces
    clc
    ret

; ---------------------------------------------------------------------------
; Commands (SI = argument string)
; ---------------------------------------------------------------------------

cmd_help:
    mov si, str_help_title
    mov bl, ATTR_TITLE
    call puts_color
    mov bx, cmd_table
.loop:
    mov si, [bx]
    test si, si
    jz .done
    push bx
    mov si, str_indent
    call puts
    pop bx
    mov si, [bx]
    mov cl, 9
    call puts_padded
    mov si, [bx + 4]
    call puts
    call newline
    add bx, 6
    jmp .loop
.done:
    ret

cmd_clear:
    call cls
    ret

cmd_echo:
    call puts
    call newline
    ret

cmd_ver:
    mov si, str_version
    call puts
    ret

cmd_time:
    mov ah, 0x02
    int 0x1A
    jc rtc_error
    mov si, str_time
    call puts
    mov al, ch
    call print_hex8
    mov al, ':'
    call putc
    mov al, cl
    call print_hex8
    mov al, ':'
    call putc
    mov al, dh
    call print_hex8
    call newline
    ret

cmd_date:
    mov ah, 0x04
    int 0x1A
    jc rtc_error
    mov si, str_date
    call puts
    mov al, ch
    call print_hex8
    mov al, cl
    call print_hex8
    mov al, '-'
    call putc
    mov al, dh
    call print_hex8
    mov al, '-'
    call putc
    mov al, dl
    call print_hex8
    call newline
    ret

rtc_error:
    mov si, str_rtc_error
    jmp print_error

cmd_uptime:
    xor ah, ah
    int 0x1A
    shl ecx, 16
    mov cx, dx
    mov eax, ecx
    sub eax, [boot_ticks]
    jns .positive
    add eax, TICKS_PER_DAY
.positive:
    mov ebx, 10
    mul ebx
    mov ebx, 182
    div ebx                 ; eax = seconds since boot
    push eax
    mov si, str_uptime
    call puts
    pop eax
    xor edx, edx
    mov ebx, 3600
    div ebx
    call print_dec
    mov si, str_hours
    call puts
    mov eax, edx
    xor edx, edx
    mov ebx, 60
    div ebx
    call print_dec
    mov si, str_minutes
    call puts
    mov eax, edx
    call print_dec
    mov si, str_seconds
    call puts
    ret

cmd_mem:
    int 0x12
    movzx eax, ax
    mov si, str_mem_base
    call puts
    call print_dec
    mov si, str_kb
    call puts

    xor cx, cx
    xor dx, dx
    mov ax, 0xE801
    int 0x15
    jc .done
    test ax, ax
    jnz .have
    mov ax, cx
    mov bx, dx
.have:
    movzx eax, ax
    movzx ebx, bx
    shl ebx, 6
    add eax, ebx
    push eax
    mov si, str_mem_ext
    call puts
    pop eax
    call print_dec
    mov si, str_kb
    call puts
    add eax, 1024
    shr eax, 10
    push eax
    mov si, str_mem_total
    call puts
    pop eax
    call print_dec
    mov si, str_mb
    call puts
.done:
    ret

cmd_cpu:
    ; CPUID is available if the ID flag (bit 21) of EFLAGS can be toggled.
    pushfd
    pop eax
    mov ecx, eax
    xor eax, 0x200000
    push eax
    popfd
    pushfd
    pop eax
    push ecx
    popfd
    xor eax, ecx
    test eax, 0x200000
    jnz .has_cpuid
    mov si, str_no_cpuid
    call puts
    ret
.has_cpuid:
    xor eax, eax
    cpuid
    mov [cpu_buf], ebx
    mov [cpu_buf + 4], edx
    mov [cpu_buf + 8], ecx
    mov byte [cpu_buf + 12], 0
    mov si, str_cpu_vendor
    call puts
    mov si, cpu_buf
    call puts
    call newline

    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000004
    jb .features
    mov di, cpu_buf
    mov esi, 0x80000002
.brand:
    mov eax, esi
    cpuid
    mov [di], eax
    mov [di + 4], ebx
    mov [di + 8], ecx
    mov [di + 12], edx
    add di, 16
    inc esi
    cmp esi, 0x80000004
    jbe .brand
    mov byte [di], 0
    mov si, str_cpu_model
    call puts
    mov si, cpu_buf
    call skip_spaces
    call puts
    call newline

.features:
    mov eax, 1
    cpuid
    mov [cpu_features], edx
    mov si, str_cpu_features
    call puts
    mov bx, cpu_feature_table
.feature_loop:
    mov si, [bx + 4]
    test si, si
    jz .features_done
    mov eax, [bx]
    test [cpu_features], eax
    jz .feature_next
    push bx
    call puts
    mov al, ' '
    call putc
    pop bx
.feature_next:
    add bx, 6
    jmp .feature_loop
.features_done:
    call newline
    ret

cmd_color:
    call parse_hex_byte
    jc .usage
    mov ah, al
    shr ah, 4
    mov bl, al
    and bl, 0x0F
    cmp ah, bl
    je .same
    mov [cur_attr], al
    call cls
    ret
.same:
    mov si, str_color_same
    jmp print_error
.usage:
    mov si, str_color_usage
    call puts
    ret

cmd_calc:
    call parse_int
    jc .usage
    mov [calc_a], eax
    call skip_spaces
    lodsb
    test al, al
    jz .usage
    mov [calc_op], al
    call parse_int
    jc .usage
    mov ecx, eax
    mov ebx, [calc_a]
    mov al, [calc_op]
    cmp al, '+'
    je .add
    cmp al, '-'
    je .sub
    cmp al, '*'
    je .mul
    cmp al, 'x'
    je .mul
    cmp al, '/'
    je .div
    cmp al, '%'
    je .div
    jmp .usage
.add:
    mov eax, ebx
    add eax, ecx
    jmp .print
.sub:
    mov eax, ebx
    sub eax, ecx
    jmp .print
.mul:
    mov eax, ebx
    imul eax, ecx
    jmp .print
.div:
    test ecx, ecx
    jz .div_zero
    cmp ecx, -1
    jne .do_div
    mov eax, ebx            ; x / -1 = -x, x % -1 = 0 (avoids #DE on INT_MIN)
    neg eax
    xor edx, edx
    jmp .div_result
.do_div:
    mov eax, ebx
    cdq
    idiv ecx
.div_result:
    cmp byte [calc_op], '%'
    jne .print
    mov eax, edx
.print:
    push eax
    mov si, str_calc_result
    call puts
    pop eax
    call print_sdec
    call newline
    ret
.div_zero:
    mov si, str_div_zero
    jmp print_error
.usage:
    mov si, str_calc_usage
    call puts
    ret

cmd_ls:
    mov di, FS_BASE
    xor dx, dx
    mov cx, FS_ENTRIES
.loop:
    cmp byte [di], 0
    je .next
    inc dx
    push cx
    mov si, str_indent
    call puts
    mov si, di
    mov cl, 16
    call puts_padded
    movzx eax, word [di + FS_SIZE_OFF]
    call print_dec
    mov si, str_bytes
    call puts
    pop cx
.next:
    add di, FS_ENTRY_SIZE
    loop .loop
    movzx eax, dx
    call print_dec
    mov si, str_files
    call puts
    mov ax, FS_ENTRIES
    sub ax, dx
    movzx eax, ax
    call print_dec
    mov si, str_free
    call puts
    ret

cmd_cat:
    call parse_name
    jc .usage
    call fs_find
    jc file_not_found
    mov cx, [di + FS_SIZE_OFF]
    lea si, [di + FS_DATA_OFF]
    xor al, al
    jcxz .end
.loop:
    lodsb
    call putc
    loop .loop
.end:
    cmp al, 10
    je .done
    call newline
.done:
    ret
.usage:
    mov si, str_cat_usage
    call puts
    ret

cmd_write:
    call parse_name
    jc .usage
    cmp byte [si], 0
    je .usage
    push si
    call fs_find
    jnc .found
    call fs_alloc
    jc .fs_full
    push si
    push di
    mov si, name_buf
    mov cx, FS_NAME_MAX + 1
    rep movsb
    pop di
    pop si
    mov word [di + FS_SIZE_OFF], 0
.found:
    pop si
    ; Length of the text to append (plus a trailing newline).
    push di
    mov di, si
    xor cx, cx
.strlen:
    cmp byte [di], 0
    je .strlen_done
    inc di
    inc cx
    jmp .strlen
.strlen_done:
    pop di
    mov ax, [di + FS_SIZE_OFF]
    mov dx, ax
    add dx, cx
    inc dx
    cmp dx, FS_DATA_MAX
    ja .file_full
    push di
    lea di, [di + FS_DATA_OFF]
    add di, ax
    rep movsb
    mov al, 10
    stosb
    pop di
    mov [di + FS_SIZE_OFF], dx
    call fs_save_entry
    ret
.fs_full:
    pop si
    mov si, str_fs_full
    jmp print_error
.file_full:
    mov si, str_file_full
    jmp print_error
.usage:
    mov si, str_write_usage
    call puts
    ret

cmd_rm:
    call parse_name
    jc .usage
    call fs_find
    jc file_not_found
    push di
    xor al, al
    mov cx, FS_ENTRY_SIZE
    rep stosb
    pop di
    call fs_save_entry
    ret
.usage:
    mov si, str_rm_usage
    call puts
    ret

file_not_found:
    mov si, str_not_found
    jmp print_error

cmd_gfx:
    mov ax, 0x0013
    int 0x10
    push es
    mov ax, 0xA000
    mov es, ax
    mov word [gfx_frame], 0
.frame:
    xor di, di
    xor dx, dx              ; y
.row:
    xor cx, cx              ; x
.pixel:
    mov ax, cx
    xor ax, dx
    add ax, [gfx_frame]
    and al, 63
    add al, 32              ; default VGA palette: hue wheel at 32..95
    stosb
    inc cx
    cmp cx, 320
    jb .pixel
    inc dx
    cmp dx, 200
    jb .row

    ; Overlay text through the BIOS (works in graphics modes).
    mov ah, 0x02
    xor bh, bh
    mov dx, 0x0000
    int 0x10
    mov si, str_gfx_hint
.hint:
    lodsb
    test al, al
    jz .hint_done
    mov ah, 0x0E
    mov bx, 0x000F
    int 0x10
    jmp .hint
.hint_done:
    inc word [gfx_frame]
    hlt                     ; ~18 fps, paced by the timer interrupt
    call key_pressed
    jnc .frame

    pop es
    mov ax, 0x0003
    int 0x10
    call cls
    mov si, str_gfx_done
    call puts
    ret

cmd_beep:
    mov si, melody
.note:
    lodsw
    test ax, ax
    jz .done
    push ax
    mov al, 0xB6            ; PIT channel 2, square wave
    out 0x43, al
    pop ax
    out 0x42, al
    mov al, ah
    out 0x42, al
    in al, 0x61
    or al, 3                ; connect speaker
    out 0x61, al
    mov cx, 3
    call wait_ticks
    jmp .note
.done:
    in al, 0x61
    and al, 0xFC
    out 0x61, al
    ret

cmd_reboot:
    mov si, str_reboot
    call puts
    mov cx, 5
    call wait_ticks
    mov cx, 0xFFFF
.wait_kbc:
    in al, 0x64
    test al, 2
    jz .reset
    loop .wait_kbc
.reset:
    mov al, 0xFE            ; pulse the CPU reset line via the keyboard controller
    out 0x64, al
    jmp 0xFFFF:0x0000

cmd_halt:
    mov si, str_halt
    mov bl, ATTR_TITLE
    call puts_color
.forever:
    cli
    hlt
    jmp .forever

; ---------------------------------------------------------------------------
; File system
; ---------------------------------------------------------------------------

; Load the file system from disk into FS_BASE.
fs_load:
    mov word [disk_lba], FS_LBA
    mov bx, FS_BASE
    mov cx, FS_SECTORS
.loop:
    mov byte [disk_cmd], 0x02
    call disk_rw
    jc .error
    add bx, 512
    inc word [disk_lba]
    loop .loop
    ret
.error:
    mov di, FS_BASE
    mov cx, FS_ENTRIES * FS_ENTRY_SIZE
    xor al, al
    rep stosb
    mov si, str_fs_load_error
    jmp print_error

; Write the entry at DI back to disk.
fs_save_entry:
    pusha
    mov ax, di
    sub ax, FS_BASE
    shr ax, 9               ; entry offset / 512 = first sector of the entry
    add ax, FS_LBA
    mov [disk_lba], ax
    mov bx, di
    mov cx, FS_ENTRY_SIZE / 512
.loop:
    mov byte [disk_cmd], 0x03
    call disk_rw
    jc .error
    add bx, 512
    inc word [disk_lba]
    loop .loop
    popa
    ret
.error:
    mov si, str_fs_save_error
    call print_error
    popa
    ret

; Find the file named name_buf. Returns DI = entry, CF=1 if not found.
fs_find:
    push si
    push cx
    mov di, FS_BASE
    mov cx, FS_ENTRIES
.loop:
    cmp byte [di], 0
    je .next
    push di
    mov si, name_buf
.cmp:
    mov al, [si]
    cmp al, [di]
    jne .mismatch
    test al, al
    jz .match
    inc si
    inc di
    jmp .cmp
.mismatch:
    pop di
.next:
    add di, FS_ENTRY_SIZE
    loop .loop
    pop cx
    pop si
    stc
    ret
.match:
    pop di
    pop cx
    pop si
    clc
    ret

; Find a free entry. Returns DI = entry, CF=1 if the file system is full.
fs_alloc:
    push cx
    mov di, FS_BASE
    mov cx, FS_ENTRIES
.loop:
    cmp byte [di], 0
    je .found
    add di, FS_ENTRY_SIZE
    loop .loop
    pop cx
    stc
    ret
.found:
    pop cx
    clc
    ret

; Copy the next word at SI into name_buf. CF=1 if missing or too long.
parse_name:
    call skip_spaces
    mov di, name_buf
    xor cx, cx
.loop:
    lodsb
    test al, al
    jz .end
    cmp al, ' '
    je .end
    cmp cx, FS_NAME_MAX
    jae .too_long
    stosb
    inc cx
    jmp .loop
.end:
    dec si
    mov byte [di], 0
    call skip_spaces
    test cx, cx
    jz .fail
    clc
    ret
.too_long:
    mov si, str_name_too_long
    call print_error
.fail:
    stc
    ret

; ---------------------------------------------------------------------------
; Disk
; ---------------------------------------------------------------------------

disk_init:
    mov ah, 0x08
    mov dl, [boot_drive]
    push es
    int 0x13
    pop es
    jc .done
    and cl, 0x3F
    jz .done
    mov [disk_spt], cl
    inc dh
    mov [disk_heads], dh
.done:
    ret

; Read (disk_cmd=2) or write (disk_cmd=3) sector [disk_lba] at ES:BX. CF=1 on error.
disk_rw:
    pusha
    mov di, 3
.retry:
    mov ax, [disk_lba]
    xor dx, dx
    xor cx, cx
    mov cl, [disk_spt]
    div cx
    inc dl
    mov cl, dl
    xor dx, dx
    push cx
    xor cx, cx
    mov cl, [disk_heads]
    div cx
    pop cx
    mov ch, al
    shl ah, 6
    or cl, ah
    mov dh, dl
    mov dl, [boot_drive]
    mov ah, [disk_cmd]
    mov al, 1
    int 0x13
    jnc .ok
    xor ax, ax
    mov dl, [boot_drive]
    int 0x13
    dec di
    jnz .retry
    popa
    stc
    ret
.ok:
    popa
    clc
    ret

; ---------------------------------------------------------------------------
; Console output
; ---------------------------------------------------------------------------

; Print character AL on screen and serial. LF is expanded to CR LF.
putc:
    push ax
    cmp al, 10
    jne .raw
    mov al, 13
    call serial_putc
    mov al, 10
.raw:
    call serial_putc
    call vga_putc
    pop ax
    ret

newline:
    push ax
    mov al, 10
    call putc
    pop ax
    ret

; Print NUL-terminated string at SI.
puts:
    push ax
    push si
.loop:
    lodsb
    test al, al
    jz .done
    call putc
    jmp .loop
.done:
    pop si
    pop ax
    ret

; Print string at SI with attribute BL.
puts_color:
    push ax
    mov al, [cur_attr]
    mov [cur_attr], bl
    call puts
    mov [cur_attr], al
    pop ax
    ret

; Print string at SI, padded with spaces to CL columns.
puts_padded:
    push ax
    push cx
    push si
.loop:
    lodsb
    test al, al
    jz .pad
    call putc
    dec cl
    jnz .loop
    jmp .done
.pad:
    mov al, ' '
.pad_loop:
    call putc
    dec cl
    jnz .pad_loop
.done:
    pop si
    pop cx
    pop ax
    ret

print_error:
    push bx
    mov bl, ATTR_ERROR
    call puts_color
    pop bx
    ret

; Print AL as two hex digits (also prints BCD values as decimal).
print_hex8:
    push ax
    push ax
    shr al, 4
    call .nibble
    pop ax
    and al, 0x0F
    call .nibble
    pop ax
    ret
.nibble:
    add al, '0'
    cmp al, '9'
    jbe .out
    add al, 7
.out:
    call putc
    ret

; Print EAX as an unsigned decimal number.
print_dec:
    pushad
    mov ebx, 10
    xor cx, cx
.divide:
    xor edx, edx
    div ebx
    push dx
    inc cx
    test eax, eax
    jnz .divide
.print:
    pop ax
    add al, '0'
    call putc
    loop .print
    popad
    ret

; Print EAX as a signed decimal number.
print_sdec:
    test eax, eax
    jns print_dec
    push eax
    mov al, '-'
    call putc
    pop eax
    neg eax
    call print_dec
    neg eax
    ret

; ---------------------------------------------------------------------------
; VGA text-mode driver
; ---------------------------------------------------------------------------

cls:
    pusha
    push es
    mov ax, 0xB800
    mov es, ax
    xor di, di
    mov ah, [cur_attr]
    mov al, ' '
    mov cx, SCREEN_COLS * SCREEN_ROWS
    rep stosw
    pop es
    mov byte [cur_row], 0
    mov byte [cur_col], 0
    call update_cursor
    popa
    ret

vga_putc:
    pusha
    push es
    cmp al, 13
    je .cr
    cmp al, 10
    je .lf
    cmp al, 8
    je .bs
    cmp al, 7
    je .done
    mov bl, al
    mov ax, 0xB800
    mov es, ax
    call cursor_offset
    mov al, bl
    mov ah, [cur_attr]
    stosw
    inc byte [cur_col]
    cmp byte [cur_col], SCREEN_COLS
    jb .done
    mov byte [cur_col], 0
    jmp .next_row
.cr:
    mov byte [cur_col], 0
    jmp .done
.lf:
    mov byte [cur_col], 0
.next_row:
    inc byte [cur_row]
    cmp byte [cur_row], SCREEN_ROWS
    jb .done
    call scroll
    mov byte [cur_row], SCREEN_ROWS - 1
    jmp .done
.bs:
    cmp byte [cur_col], 0
    je .bs_wrap
    dec byte [cur_col]
    jmp .done
.bs_wrap:
    cmp byte [cur_row], 0
    je .done
    dec byte [cur_row]
    mov byte [cur_col], SCREEN_COLS - 1
.done:
    call update_cursor
    pop es
    popa
    ret

; DI = video memory offset of the cursor.
cursor_offset:
    push ax
    movzx ax, byte [cur_row]
    mov di, SCREEN_COLS
    mul di
    movzx di, byte [cur_col]
    add di, ax
    shl di, 1
    pop ax
    ret

scroll:
    pusha
    push ds
    push es
    mov bh, [cur_attr]
    mov ax, 0xB800
    mov ds, ax
    mov es, ax
    mov si, SCREEN_COLS * 2
    xor di, di
    mov cx, SCREEN_COLS * (SCREEN_ROWS - 1)
    rep movsw
    mov ah, bh
    mov al, ' '
    mov cx, SCREEN_COLS
    rep stosw
    pop es
    pop ds
    popa
    ret

update_cursor:
    pusha
    call cursor_offset
    shr di, 1
    mov bx, di
    mov dx, 0x3D4
    mov al, 0x0F
    out dx, al
    inc dx
    mov al, bl
    out dx, al
    dec dx
    mov al, 0x0E
    out dx, al
    inc dx
    mov al, bh
    out dx, al
    popa
    ret

; ---------------------------------------------------------------------------
; Serial port (COM1, 115200 8N1)
; ---------------------------------------------------------------------------

serial_init:
    push ax
    push dx
    mov dx, COM1 + 1
    xor al, al
    out dx, al              ; disable interrupts
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al              ; DLAB on
    mov dx, COM1
    mov al, 1
    out dx, al              ; divisor low (115200 baud)
    inc dx
    xor al, al
    out dx, al              ; divisor high
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al              ; 8N1, DLAB off
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al              ; enable FIFO
    mov dx, COM1 + 4
    mov al, 0x0B
    out dx, al              ; DTR, RTS, OUT2
    pop dx
    pop ax
    ret

serial_putc:
    push ax
    push cx
    push dx
    mov ah, al
    mov cx, 0xFFFF
    mov dx, COM1 + 5
.wait:
    in al, dx
    test al, 0x20
    jnz .send
    loop .wait
    jmp .done
.send:
    mov al, ah
    mov dx, COM1
    out dx, al
.done:
    pop dx
    pop cx
    pop ax
    ret

; ---------------------------------------------------------------------------
; Console input
; ---------------------------------------------------------------------------

; Wait for a key from the keyboard or serial port.
; Returns AL = ASCII (0 for special keys) and AH = scan code.
getc:
    push dx
.poll:
    mov ah, 0x01
    int 0x16
    jnz .keyboard
    mov dx, COM1 + 5
    in al, dx
    test al, 1
    jnz .serial
    hlt
    jmp .poll
.keyboard:
    xor ah, ah
    int 0x16
    cmp al, 0xE0
    jne .done
    xor al, al
    jmp .done
.serial:
    mov dx, COM1
    in al, dx
    xor ah, ah
.done:
    pop dx
    ret

; CF=1 (and the key is consumed) if a key is waiting on keyboard or serial.
key_pressed:
    push ax
    push dx
    mov ah, 0x01
    int 0x16
    jnz .yes
    mov dx, COM1 + 5
    in al, dx
    test al, 1
    jnz .yes
    pop dx
    pop ax
    clc
    ret
.yes:
    call getc
    pop dx
    pop ax
    stc
    ret

; Read a line into line_buf with echo, backspace and history (Up arrow).
readline:
    mov di, line_buf
    xor cx, cx
.loop:
    call getc
    cmp al, 13
    je .enter
    cmp al, 10
    je .enter
    cmp al, 8
    je .backspace
    cmp al, 127
    je .backspace
    cmp al, 27
    je .escape
    test al, al
    jz .special
    cmp al, ' '
    jb .loop
    cmp al, '~'
    ja .loop
    cmp cx, LINE_MAX
    jae .loop
    stosb
    inc cx
    call putc
    jmp .loop
.backspace:
    jcxz .loop
    dec di
    dec cx
    call erase_char
    jmp .loop
.escape:                    ; ANSI arrow keys from a serial terminal: ESC [ A
    call getc
    cmp al, '['
    jne .loop
    call getc
    cmp al, 'A'
    je .history
    jmp .loop
.special:
    cmp ah, 0x48            ; Up arrow
    je .history
    jmp .loop
.history:
    jcxz .recall
    call erase_char
    dec cx
    jmp .history
.recall:
    mov di, line_buf
    mov si, hist_buf
.recall_loop:
    lodsb
    test al, al
    jz .loop
    stosb
    inc cx
    call putc
    jmp .recall_loop
.enter:
    mov byte [di], 0
    call newline
    jcxz .done
    mov si, line_buf
    mov di, hist_buf
    inc cx
    rep movsb
.done:
    ret

erase_char:
    push ax
    mov al, 8
    call putc
    mov al, ' '
    call putc
    mov al, 8
    call putc
    pop ax
    ret

; ---------------------------------------------------------------------------
; Helpers
; ---------------------------------------------------------------------------

skip_spaces:
    cmp byte [si], ' '
    jne .done
    inc si
    jmp skip_spaces
.done:
    ret

to_lower:
    cmp al, 'A'
    jb .done
    cmp al, 'Z'
    ja .done
    add al, 32
.done:
    ret

; Parse a signed decimal integer at SI into EAX. CF=1 if no digits.
parse_int:
    push ecx
    push edx
    call skip_spaces
    xor eax, eax
    xor edx, edx            ; dl = negative flag, dh = digit seen
    cmp byte [si], '-'
    jne .digits
    inc dl
    inc si
.digits:
    movzx ecx, byte [si]
    sub cl, '0'
    jb .end
    cmp cl, 9
    ja .end
    imul eax, eax, 10
    add eax, ecx
    mov dh, 1
    inc si
    jmp .digits
.end:
    test dh, dh
    jz .fail
    test dl, dl
    jz .ok
    neg eax
.ok:
    pop edx
    pop ecx
    clc
    ret
.fail:
    pop edx
    pop ecx
    stc
    ret

; Parse exactly two hex digits at SI into AL. CF=1 on error.
parse_hex_byte:
    push bx
    call skip_spaces
    lodsb
    call hex_digit
    jc .fail
    mov bl, al
    lodsb
    call hex_digit
    jc .fail
    shl bl, 4
    or al, bl
    mov bl, [si]
    cmp bl, 0
    je .ok
    cmp bl, ' '
    jne .fail
.ok:
    pop bx
    clc
    ret
.fail:
    pop bx
    stc
    ret

hex_digit:
    call to_lower
    cmp al, '0'
    jb .fail
    cmp al, '9'
    jbe .dec
    cmp al, 'a'
    jb .fail
    cmp al, 'f'
    ja .fail
    sub al, 'a' - 10
    clc
    ret
.dec:
    sub al, '0'
    clc
    ret
.fail:
    stc
    ret

; Wait CX timer ticks (~55 ms each).
wait_ticks:
    push ax
.tick:
    mov ax, [BDA_TICKS]
.wait:
    hlt
    cmp ax, [BDA_TICKS]
    je .wait
    loop .tick
    pop ax
    ret

; ---------------------------------------------------------------------------
; Data
; ---------------------------------------------------------------------------

; name, handler, description
cmd_table:
    dw n_help,   cmd_help,   d_help
    dw n_clear,  cmd_clear,  d_clear
    dw n_cls,    cmd_clear,  d_clear
    dw n_echo,   cmd_echo,   d_echo
    dw n_ver,    cmd_ver,    d_ver
    dw n_time,   cmd_time,   d_time
    dw n_date,   cmd_date,   d_date
    dw n_uptime, cmd_uptime, d_uptime
    dw n_mem,    cmd_mem,    d_mem
    dw n_cpu,    cmd_cpu,    d_cpu
    dw n_color,  cmd_color,  d_color
    dw n_calc,   cmd_calc,   d_calc
    dw n_ls,     cmd_ls,     d_ls
    dw n_cat,    cmd_cat,    d_cat
    dw n_write,  cmd_write,  d_write
    dw n_rm,     cmd_rm,     d_rm
    dw n_gfx,    cmd_gfx,    d_gfx
    dw n_beep,   cmd_beep,   d_beep
    dw n_reboot, cmd_reboot, d_reboot
    dw n_halt,   cmd_halt,   d_halt
    dw 0

n_help   db "help", 0
n_clear  db "clear", 0
n_cls    db "cls", 0
n_echo   db "echo", 0
n_ver    db "ver", 0
n_time   db "time", 0
n_date   db "date", 0
n_uptime db "uptime", 0
n_mem    db "mem", 0
n_cpu    db "cpu", 0
n_color  db "color", 0
n_calc   db "calc", 0
n_ls     db "ls", 0
n_cat    db "cat", 0
n_write  db "write", 0
n_rm     db "rm", 0
n_gfx    db "gfx", 0
n_beep   db "beep", 0
n_reboot db "reboot", 0
n_halt   db "halt", 0

d_help   db "Show this help", 0
d_clear  db "Clear the screen", 0
d_echo   db "Print text: echo <text>", 0
d_ver    db "Show the OS version", 0
d_time   db "Show the current time (RTC)", 0
d_date   db "Show the current date (RTC)", 0
d_uptime db "Show time since boot", 0
d_mem    db "Show installed memory", 0
d_cpu    db "Show CPU vendor, model and features", 0
d_color  db "Set colors: color <bg><fg>, e.g. color 0A", 0
d_calc   db "Calculator: calc 12 * 34 (+ - * / %)", 0
d_ls     db "List files", 0
d_cat    db "Show a file: cat <name>", 0
d_write  db "Append a line: write <name> <text>", 0
d_rm     db "Delete a file: rm <name>", 0
d_gfx    db "VGA 320x200 graphics demo", 0
d_beep   db "Play a sound on the PC speaker", 0
d_reboot db "Restart the computer", 0
d_halt   db "Halt the CPU", 0

cpu_feature_table:
    dd 1 << 0
    dw f_fpu
    dd 1 << 4
    dw f_tsc
    dd 1 << 8
    dw f_cx8
    dd 1 << 15
    dw f_cmov
    dd 1 << 23
    dw f_mmx
    dd 1 << 25
    dw f_sse
    dd 1 << 26
    dw f_sse2
    dd 0
    dw 0

f_fpu  db "FPU", 0
f_tsc  db "TSC", 0
f_cx8  db "CX8", 0
f_cmov db "CMOV", 0
f_mmx  db "MMX", 0
f_sse  db "SSE", 0
f_sse2 db "SSE2", 0

; PIT divisors (1193182 / frequency): C5 E5 G5 C6
melody dw 2280, 1810, 1521, 1140, 0

str_banner:
    db "  __  __ _       _  ___  ____  ", 10
    db " |  \/  (_)_ __ (_)/ _ \/ ___| ", 10
    db " | |\/| | | '_ \| | | | \___ \ ", 10
    db " | |  | | | | | | | |_| |___) |", 10
    db " |_|  |_|_|_| |_|_|\___/|____/ ", 10, 10, 0
str_welcome:
    db "MiniOS 1.0 - a tiny 16-bit operating system running in your browser.", 10
    db "Type 'help' for a list of commands.", 10, 10, 0
str_version:
    db "MiniOS version 1.0 (x86 real mode, 16-bit)", 10, 0
str_prompt       db "minios> ", 0
str_unknown      db "Unknown command: ", 0
str_unknown2     db 10, "Type 'help' for a list of commands.", 10, 0
str_help_title   db "Available commands:", 10, 0
str_indent       db "  ", 0
str_time         db "Time: ", 0
str_date         db "Date: ", 0
str_rtc_error    db "RTC is not available.", 10, 0
str_uptime       db "Uptime: ", 0
str_hours        db "h ", 0
str_minutes      db "m ", 0
str_seconds      db "s", 10, 0
str_mem_base     db "Base memory:     ", 0
str_mem_ext      db "Extended memory: ", 0
str_mem_total    db "Total:           ", 0
str_kb           db " KB", 10, 0
str_mb           db " MB", 10, 0
str_no_cpuid     db "CPUID is not supported (pre-486 CPU).", 10, 0
str_cpu_vendor   db "Vendor:   ", 0
str_cpu_model    db "Model:    ", 0
str_cpu_features db "Features: ", 0
str_color_same   db "Foreground and background must differ.", 10, 0
str_color_usage:
    db "Usage: color <bg><fg>   (two hex digits, e.g. color 1F)", 10
    db "  0 Black   4 Red      8 DarkGray   C LightRed", 10
    db "  1 Blue    5 Magenta  9 LightBlue  D LightMagenta", 10
    db "  2 Green   6 Brown    A LightGreen E Yellow", 10
    db "  3 Cyan    7 Gray     B LightCyan  F White", 10, 0
str_calc_usage   db "Usage: calc <a> <op> <b>   (op: + - * / %)", 10, 0
str_calc_result  db "= ", 0
str_div_zero     db "Division by zero.", 10, 0
str_bytes        db " bytes", 10, 0
str_files        db " file(s), ", 0
str_free         db " free slot(s)", 10, 0
str_cat_usage    db "Usage: cat <name>", 10, 0
str_write_usage  db "Usage: write <name> <text>", 10, 0
str_rm_usage     db "Usage: rm <name>", 10, 0
str_not_found    db "File not found.", 10, 0
str_name_too_long db "File name too long (max 13 characters).", 10, 0
str_fs_full      db "No free file slots.", 10, 0
str_file_full    db "File is full (max 1008 bytes).", 10, 0
str_fs_load_error db "Warning: could not load the file system.", 10, 0
str_fs_save_error db "Error: could not write to disk.", 10, 0
str_gfx_hint     db " MiniOS VGA demo - press any key ", 0
str_gfx_done     db "Back in text mode.", 10, 0
str_reboot       db "Rebooting...", 10, 0
str_halt         db "System halted. It is now safe to turn off your computer.", 10, 0

; Variables
boot_drive   db 0
disk_spt     db 18
disk_heads   db 2
disk_cmd     db 0
disk_lba     dw 0
cur_row      db 0
cur_col      db 0
cur_attr     db ATTR_DEFAULT
calc_op      db 0
calc_a       dd 0
gfx_frame    dw 0
boot_ticks   dd 0
cpu_features dd 0
cpu_buf      times 52 db 0
name_buf     times FS_NAME_MAX + 1 db 0
line_buf     times LINE_MAX + 1 db 0
hist_buf     times LINE_MAX + 1 db 0

; Pad to the fixed kernel size; fails to assemble if the kernel is too large.
times KERNEL_SECTORS * 512 - ($ - $$) db 0
