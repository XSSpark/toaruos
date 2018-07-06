ifeq ($(TOOLCHAIN),)
  ifeq ($(shell util/check.sh),y)
    export PATH := $(shell util/activate.sh)
  else
    FOO := $(shell util/prompt.sh)
    ifeq ($(shell util/check.sh),y)
      export PATH := $(shell util/activate.sh)
    else
      $(error "No toolchain, and you did not ask to build it.")
    endif
  endif
endif

# Prevents Make from removing intermediary files on failure
.SECONDARY:

# Disable built-in rules
.SUFFIXES:

TARGET_TRIPLET=i686-pc-toaru

# Userspace flags

CC=$(TARGET_TRIPLET)-gcc
AR=$(TARGET_TRIPLET)-ar
AS=$(TARGET_TRIPLET)-as
CFLAGS= -O3 -g -std=gnu99 -I. -Iapps -pipe -mmmx -msse -msse2 -fplan9-extensions -Wall -Wextra -Wno-unused-parameter

LIBC_OBJS  = $(patsubst %.c,%.o,$(wildcard libc/*.c))
LIBC_OBJS += $(patsubst %.c,%.o,$(wildcard libc/*/*.c))
LIBC_OBJS += libc/setjmp.o
LC=base/lib/libc.so

APPS=$(patsubst apps/%.c,%,$(wildcard apps/*.c))
APPS_X=$(foreach app,$(APPS),base/bin/$(app))
APPS_Y=$(foreach app,$(filter-out init,$(APPS)),.make/$(app).mak)

LIBS=$(patsubst lib/%.c,%,$(wildcard lib/*.c))
LIBS_X=$(foreach lib,$(LIBS),base/lib/libtoaru_$(lib).so)
LIBS_Y=$(foreach lib,$(LIBS),.make/$(lib).lmak)

all: image.iso

# Kernel / module flags

KCC = $(TARGET_TRIPLET)-gcc
KAS = $(TARGET_TRIPLET)-as
KLD = $(TARGET_TRIPLET)-ld
KNM = $(TARGET_TRIPLET)-nm

KCFLAGS  = -O2 -std=c99
KCFLAGS += -finline-functions -ffreestanding
KCFLAGS += -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-format
KCFLAGS += -pedantic -fno-omit-frame-pointer
KCFLAGS += -D_KERNEL_
KCFLAGS += -DKERNEL_GIT_TAG=$(shell util/make-version)
KASFLAGS = --32

KERNEL_OBJS = $(patsubst %.c,%.o,$(wildcard kernel/*.c))
KERNEL_OBJS += $(patsubst %.c,%.o,$(wildcard kernel/*/*.c))
KERNEL_OBJS += $(patsubst %.c,%.o,$(wildcard kernel/*/*/*.c))

KERNEL_ASMOBJS = $(filter-out kernel/symbols.o,$(patsubst %.S,%.o,$(wildcard kernel/*.S)))

# Kernel

cdrom/kernel: ${KERNEL_ASMOBJS} ${KERNEL_OBJS} kernel/symbols.o
	${KCC} -T kernel/link.ld ${KCFLAGS} -nostdlib -o $@ ${KERNEL_ASMOBJS} ${KERNEL_OBJS} kernel/symbols.o -lgcc

kernel/symbols.o: ${KERNEL_ASMOBJS} ${KERNEL_OBJS} util/generate_symbols.py
	-rm -f kernel/symbols.o
	${KCC} -T kernel/link.ld ${KCFLAGS} -nostdlib -o .toaruos-kernel ${KERNEL_ASMOBJS} ${KERNEL_OBJS} -lgcc
	${KNM} .toaruos-kernel -g | util/generate_symbols.py > kernel/symbols.S
	${KAS} ${KASFLAGS} kernel/symbols.S -o $@
	-rm -f .toaruos-kernel

kernel/sys/version.o: kernel/*/*.c kernel/*.c

kernel/%.o: kernel/%.S
	${KAS} ${ASFLAGS} $< -o $@

kernel/%.o: kernel/%.c ${HEADERS}
	${KCC} ${KCFLAGS} -nostdlib -g -c -o $@ $<

# Modules

cdrom/mod:
	@mkdir -p $@

MODULES = $(patsubst modules/%.c,cdrom/mod/%.ko,$(wildcard modules/*.c))

HEADERS = $(shell find base/usr/include/kernel -type f -name '*.h')

cdrom/mod/%.ko: modules/%.c ${HEADERS} | cdrom/mod
	${KCC} -T modules/link.ld -nostdlib ${KCFLAGS} -c -o $@ $<

modules: ${MODULES}

# Root Filesystem

base/dev:
	mkdir -p base/dev
base/tmp:
	mkdir -p base/tmp
base/proc:
	mkdir -p base/proc
base/bin:
	mkdir -p base/bin
base/lib:
	mkdir -p base/lib
cdrom/boot:
	mkdir -p cdrom/boot
.make:
	mkdir -p .make
dirs: base/dev base/tmp base/proc base/bin base/lib cdrom/boot .make

# C Library

crts: base/lib/crt0.o base/lib/crti.o base/lib/crtn.o | dirs

base/lib/crt%.o: libc/crt%.s
	yasm -f elf -o $@ $<

libc/setjmp.o: libc/setjmp.S
	$(AS) -o $@ $<

libc/%.o: libc/%.c
	$(CC) $(CFLAGS) -fPIC -c -o $@ $<

base/lib/libc.a: ${LIBC_OBJS} | dirs crts
	$(AR) cr $@ $^

base/lib/libc.so: ${LIBC_OBJS} | dirs crts
	$(CC) -nodefaultlibs -o $@ $(CFLAGS) -shared -fPIC $^ -lgcc

base/lib/libm.so: util/lm.c | dirs crts
	$(CC) -nodefaultlibs -o $@ $(CFLAGS) -shared -fPIC $^ -lgcc

# Userspace Linker/Loader

base/lib/ld.so: linker/linker.c base/lib/libc.a | dirs
	$(CC) -static -Wl,-static $(CFLAGS) -o $@ -Os -T linker/link.ld $<

# Shared Libraries
.make/%.lmak: lib/%.c util/auto-dep.py | dirs
	util/auto-dep.py --makelib $< > $@

ifeq (,$(findstring clean,$(MAKECMDGOALS)))
-include ${LIBS_Y}
endif

# Init (static)

base/bin/init: apps/init.c base/lib/libc.a | dirs
	$(CC) -static -Wl,-static $(CFLAGS) -o $@ $<

cdrom/netinit: util/netinit.c base/lib/libc.a | dirs
	$(CC) -s -static -Wl,-static $(CFLAGS) -o $@ $<

# Userspace applications

.make/%.mak: apps/%.c util/auto-dep.py | dirs
	util/auto-dep.py --make $< > $@

ifeq (,$(findstring clean,$(MAKECMDGOALS)))
-include ${APPS_Y}
endif

# Ramdisk

cdrom/ramdisk.img: ${APPS_X} ${LIBS_X} base/lib/ld.so base/lib/libm.so $(shell find base) Makefile | dirs
	genext2fs -B 4096 -d base -D util/devtable -U -b `util/calc-size.sh` -N 2048 cdrom/ramdisk.img

# CD image

ifeq (,$(wildcard /usr/lib32/crt0-efi-ia32.o))
    EFI_XORRISO=
    EFI_BOOT=
else
    EFI_XORRISO=-eltorito-alt-boot -e boot/efi.img -no-emul-boot -isohybrid-gpt-basdat
    EFI_BOOT=cdrom/boot/efi.img
endif


image.iso: cdrom/ramdisk.img cdrom/boot/boot.sys cdrom/kernel cdrom/netinit ${MODULES}
	xorriso -as mkisofs -R -J -c boot/bootcat \
	  -b boot/boot.sys -no-emul-boot -boot-load-size 20 \
	  ${EFI_XORRISO} \
	  -o image.iso cdrom

# Boot loader

cdrom/boot/efi.img: boot/boot32.efi
	-rm -f $@
	fallocate -l 32M $@
	mkfs.fat $@
	-mmd  -i $@ '/EFI'
	-mmd  -i $@ '/EFI/BOOT'
	mcopy -i $@ boot/boot32.efi '::/EFI/BOOT/BOOTIA32.EFI'

EFI_CFLAGS=-fno-stack-protector -fpic -DEFI_FUNCTION_WRAPPER -m32 -ffreestanding -fshort-wchar -I /usr/include/efi -I /usr/include/efi/ia32 -mno-red-zone
EFI_SECTIONS=-j .text -j .sdata -j .data -j .dynamic -j .dynsym -j .rel -j .rela -j .reloc

boot/efi.so: boot/efi.c boot/jmp.o
	$(CC) ${EFI_CFLAGS} -c -o boot/efi.o $<
	$(LD) boot/efi.o /usr/lib32/crt0-efi-ia32.o -nostdlib -znocombreloc -T /usr/lib32/elf_ia32_efi.lds -shared -Bsymbolic -L /usr/lib32 -lefi -lgnuefi -o boot/efi.so

boot/boot32.efi: boot/efi.so
	objcopy ${EFI_SECTIONS} --target=efi-app-ia32 boot/efi.so boot/boot32.efi

cdrom/boot/boot.sys: boot/boot.o boot/cstuff.o boot/link.ld ${EFI_BOOT} | cdrom/boot
	${KLD} -T boot/link.ld -o $@ boot/boot.o boot/cstuff.o

boot/cstuff.o: boot/cstuff.c boot/*.h
	${KCC} -c -Os -o $@ $<

boot/boot.o: boot/boot.s
	yasm -f elf -o $@ $<

boot/jmp.o: boot/jmp.s
	yasm -f elf -o $@ $<

.PHONY: clean
clean:
	rm -f base/lib/*.so
	rm -f base/lib/libc.a
	rm -f ${APPS_X}
	rm -f libc/*.o libc/*/*.o
	rm -f image.iso
	rm -f cdrom/ramdisk.img
	rm -f cdrom/boot/boot.sys
	rm -f boot/*.o
	rm -f boot/*.efi
	rm -f boot/*.so
	rm -f cdrom/boot/efi.img
	rm -f cdrom/kernel
	rm -f cdrom/netboot cdrom/netinit
	rm -f ${KERNEL_OBJS} ${KERNEL_ASMOBJS} kernel/symbols.o kernel/symbols.S
	rm -f base/lib/crt*.o
	rm -f ${MODULES}
	rm -f ${APPS_Y} ${LIBS_Y}

QEMU_ARGS=-serial mon:stdio -m 1G -soundhw ac97,pcspk -enable-kvm

.PHONY: run
run: image.iso
	qemu-system-i386 -cdrom $< ${QEMU_ARGS}

.PHONY: fast
fast: image.iso
	qemu-system-i386 -cdrom $< ${QEMU_ARGS} \
	  -fw_cfg name=opt/org.toaruos.bootmode,string=0

.PHONY: headless
headless: image.iso
	@echo "=== Launching qemu headless."
	@echo "=== To quit qemu, use 'Ctrl-a c' to access monitor"
	@echo "=== and type 'quit' to exit."
	qemu-system-i386 -cdrom $< ${QEMU_ARGS} \
	  -nographic \
	  -fw_cfg name=opt/org.toaruos.bootmode,string=3

.PHONY: virtualbox
VMNAME=ToaruOS-NIH CD
virtualbox: image.iso
	-VBoxManage unregistervm "$(VMNAME)" --delete
	VBoxManage createvm --name "$(VMNAME)" --ostype "Other" --register
	VBoxManage modifyvm "$(VMNAME)" --memory 1024 --vram 32 --audio pulse --audiocontroller ac97 --bioslogodisplaytime 1 --bioslogofadeout off --bioslogofadein off --biosbootmenu disabled
	VBoxManage storagectl "$(VMNAME)" --add ide --name "IDE"
	VBoxManage storageattach "$(VMNAME)" --storagectl "IDE" --port 0 --device 0 --medium $(shell pwd)/image.iso --type dvddrive
	VBoxManage setextradata "$(VMNAME)" GUI/DefaultCloseAction PowerOff
	VBoxManage startvm "$(VMNAME)" --type separate


