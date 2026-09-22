# MiSTer-Pet
#
#   make            cross-build the spike for the MiSTer (static, armv7/Cortex-A9)
#   make host       native build for poking at it on the desktop (--fake/--ppm)
#   make deploy HOST=192.168.1.x
#   make clean

CROSS   ?= arm-linux-gnueabihf-
ARMCC   := $(CROSS)gcc
HOSTCC  ?= cc

ARMFLAGS := -march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard
CFLAGS   := -std=c99 -O2 -Wall -Wextra -Wno-unused-parameter
LDLIBS   := -lm

ARMBIN  := build/arm/misterpet-spike
ARMTOG  := build/arm/fbterm-toggle
HOSTBIN := build/host/misterpet-spike

HOST    ?= mister.local
DEST    ?= /media/fat/pet

.PHONY: all host deploy clean

all: $(ARMBIN) $(ARMTOG)

$(ARMBIN): src/spike_fb.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $< $(LDLIBS)
	@$(CROSS)size $@ 2>/dev/null || true
	@file $@ 2>/dev/null || true

$(ARMTOG): src/fbterm_toggle.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

host: $(HOSTBIN)

$(HOSTBIN): src/spike_fb.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $< $(LDLIBS)

build/arm build/host:
	mkdir -p $@

deploy: $(ARMBIN) $(ARMTOG)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
