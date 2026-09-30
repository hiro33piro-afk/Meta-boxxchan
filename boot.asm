; MiniOS boot sector
; BIOS loads this 512-byte sector at 0000:7C00 and jumps here.
; It loads the kernel (KERNEL_SECTORS sectors starting at LBA 1)
; to 0000:8000 and jumps to it with DL = boot drive.

bits 16
org 0x7C00

%ifndef KERNEL_SECTORS
%define KERNEL_SECTORS 32
%endif

KERNEL_OFF equ 0x8000

start:
    cli
    xor ax, ax
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov sp, 0x7C00
    sti
    cld

    mov [boot_drive], dl

    mov si, msg_loading
    call print

    ; Query drive geometry (sectors per track / heads).
    ; Keep the 1.44 MB floppy defaults if the BIOS call fails.
    mov ah, 0x08
    mov dl, [boot_drive]
    push es
    int 0x13
    pop es
    jc .geometry_done
    and cl, 0x3F
    jz .geometry_done
    mov [spt], cl
    inc dh
    mov [heads], dh
.geometry_done:

    mov word [lba], 1
    mov bx, KERNEL_OFF
    mov cx, KERNEL_SECTORS
.next_sector:
    push cx
    call read_sector
    add bx, 512
    inc word [lba]
    mov al, '.'
    call putc
    pop cx
    loop .next_sector

    mov si, msg_ok
    call print

    mov dl, [boot_drive]
    jmp 0x0000:KERNEL_OFF

; Read sector [lba] into ES:BX (LBA -> CHS conversion, 3 retries).
read_sector:
    mov di, 3
.retry:
    mov ax, [lba]
    xor dx, dx
    xor cx, cx
    mov cl, [spt]
    div cx                  ; ax = lba / spt, dx = lba % spt
    inc dl
    mov cl, dl              ; sector (1-based)
    xor dx, dx
    push cx
    xor cx, cx
    mov cl, [heads]
    div cx                  ; ax = cylinder, dx = head
    pop cx
    mov ch, al              ; cylinder low 8 bits
    shl ah, 6
    or cl, ah               ; cylinder bits 8-9
    mov dh, dl              ; head
    mov dl, [boot_drive]
    mov ax, 0x0201
    int 0x13
    jnc .done
    xor ax, ax              ; reset controller and retry
    mov dl, [boot_drive]
    int 0x13
    dec di
    jnz .retry
    mov si, msg_error
    call print
.hang:
    cli
    hlt
    jmp .hang
.done:
    ret

print:
    lodsb
    test al, al
    jz .end
    call putc
    jmp print
.end:
    ret

putc:
    mov ah, 0x0E
    push bx
    xor bx, bx
    int 0x10
    pop bx
    ret

boot_drive  db 0
spt         db 18
heads       db 2
lba         dw 0

msg_loading db "MiniOS boot: loading kernel", 0
msg_ok      db " OK", 13, 10, 0
msg_error   db 13, 10, "Disk read error. System halted.", 0

times 510 - ($ - $$) db 0
dw 0xAA55
