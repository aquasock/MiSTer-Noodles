# MiSTer-Noodles
#
#   make            cross-build the ARM-side host tools (static, armv7/Cortex-A9)
#   make host       native build for poking at the tools on the desktop
#   make deploy HOST=192.168.1.x
#   make sim        Verilator simulation of the RTL engine (CMDQ/BLIT/LINK)
#   make clean

CROSS   ?= arm-linux-gnueabihf-
ARMCC   := $(CROSS)gcc
HOSTCC  ?= cc

ARMFLAGS := -march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard
CFLAGS   := -std=c99 -O2 -Wall -Wextra -Wno-unused-parameter

ARMLINK     := build/arm/link-push
ARMSLOTDUMP := build/arm/link-slot-dump
ARMMEMSCAN  := build/arm/mem-scan
ARMCOPYPUSH := build/arm/blit-copy-push
ARMFILLPUSH := build/arm/solid-fill-push
ARMKEYPUSH  := build/arm/blit-copy-key-push
ARMBENCH    := build/arm/bench
ARMPRESENT  := build/arm/present-demo
ARMSPRITE   := build/arm/sprite-demo
ARMLOADBMP  := build/arm/load-bmp
HOSTLINK    := build/host/link-push
HOSTSLOTDUMP:= build/host/link-slot-dump
HOSTMEMSCAN := build/host/mem-scan
HOSTCOPYPUSH:= build/host/blit-copy-push
HOSTFILLPUSH:= build/host/solid-fill-push
HOSTKEYPUSH := build/host/blit-copy-key-push
HOSTBENCH   := build/host/bench
HOSTPRESENT := build/host/present-demo
HOSTSPRITE  := build/host/sprite-demo
HOSTLOADBMP := build/host/load-bmp

HOST    ?= mister.local
DEST    ?= /media/fat/pet

VERILATOR ?= verilator
SIM_DIR   := build/sim

SOLID_FILL_SIM    := $(SIM_DIR)/solid_fill/Vengine_dut
DDRAM_ADAPTER_SIM := $(SIM_DIR)/ddram_adapter/Vengine_ddram_dut
BLIT_COPY_SIM     := $(SIM_DIR)/blit_copy/Vengine_copy_dut
LINK_RING_SIM     := $(SIM_DIR)/link_ring/Vlink_ring_dut
LINK_FENCE_SIM    := $(SIM_DIR)/link_fence/Vlink_fence_dut
PRESENT_SIM       := $(SIM_DIR)/present/Vpresent_dut

.PHONY: all host deploy sim clean

all: $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP)

sim: $(SOLID_FILL_SIM) $(DDRAM_ADAPTER_SIM) $(BLIT_COPY_SIM) $(LINK_RING_SIM) $(LINK_FENCE_SIM) $(PRESENT_SIM)
	$(SOLID_FILL_SIM)
	$(DDRAM_ADAPTER_SIM)
	$(BLIT_COPY_SIM)
	$(LINK_RING_SIM)
	$(LINK_FENCE_SIM)
	$(PRESENT_SIM)

$(SOLID_FILL_SIM): rtl/cmdq.sv rtl/blit.sv sim/engine_dut.sv sim/tb_solid_fill.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv sim/engine_dut.sv sim/tb_solid_fill.cpp -o $(notdir $@)

$(DDRAM_ADAPTER_SIM): rtl/cmdq.sv rtl/blit.sv rtl/ddram_adapter.sv sim/engine_ddram_dut.sv sim/tb_ddram_adapter.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_ddram_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv rtl/ddram_adapter.sv sim/engine_ddram_dut.sv sim/tb_ddram_adapter.cpp -o $(notdir $@)

$(BLIT_COPY_SIM): rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/ddram_adapter.sv sim/engine_copy_dut.sv sim/tb_blit_copy.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_copy_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/ddram_adapter.sv sim/engine_copy_dut.sv sim/tb_blit_copy.cpp -o $(notdir $@)

$(LINK_RING_SIM): rtl/link_ring.sv rtl/ddram_adapter.sv sim/link_ring_dut.sv sim/tb_link_ring.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module link_ring_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/link_ring.sv rtl/ddram_adapter.sv sim/link_ring_dut.sv sim/tb_link_ring.cpp -o $(notdir $@)

$(LINK_FENCE_SIM): rtl/link_fence.sv sim/link_fence_dut.sv sim/tb_link_fence.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module link_fence_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/link_fence.sv sim/link_fence_dut.sv sim/tb_link_fence.cpp -o $(notdir $@)

$(PRESENT_SIM): rtl/present.sv sim/present_dut.sv sim/tb_present.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module present_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/present.sv sim/present_dut.sv sim/tb_present.cpp -o $(notdir $@)

$(ARMLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/link_push.c lib/noodles_link.c

$(ARMSLOTDUMP): tools/link_slot_dump.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMMEMSCAN): tools/mem_scan.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMCOPYPUSH): tools/blit_copy_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/blit_copy_push.c lib/noodles_link.c

$(ARMFILLPUSH): tools/solid_fill_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/solid_fill_push.c lib/noodles_link.c

$(ARMKEYPUSH): tools/blit_copy_key_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/blit_copy_key_push.c lib/noodles_link.c

$(ARMBENCH): tools/bench.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/bench.c lib/noodles_link.c

$(ARMPRESENT): tools/present_demo.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/present_demo.c lib/noodles_link.c

$(ARMSPRITE): tools/sprite_demo.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/sprite_demo.c lib/noodles_link.c

$(ARMLOADBMP): tools/load_bmp.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/load_bmp.c lib/noodles_link.c

host: $(HOSTLINK) $(HOSTSLOTDUMP) $(HOSTMEMSCAN) $(HOSTCOPYPUSH) $(HOSTFILLPUSH) $(HOSTKEYPUSH) $(HOSTBENCH) $(HOSTPRESENT) $(HOSTSPRITE) $(HOSTLOADBMP)

$(HOSTLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/link_push.c lib/noodles_link.c

$(HOSTSLOTDUMP): tools/link_slot_dump.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTMEMSCAN): tools/mem_scan.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTCOPYPUSH): tools/blit_copy_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/blit_copy_push.c lib/noodles_link.c

$(HOSTFILLPUSH): tools/solid_fill_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/solid_fill_push.c lib/noodles_link.c

$(HOSTKEYPUSH): tools/blit_copy_key_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/blit_copy_key_push.c lib/noodles_link.c

$(HOSTBENCH): tools/bench.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/bench.c lib/noodles_link.c

$(HOSTPRESENT): tools/present_demo.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/present_demo.c lib/noodles_link.c

$(HOSTSPRITE): tools/sprite_demo.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/sprite_demo.c lib/noodles_link.c

$(HOSTLOADBMP): tools/load_bmp.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/load_bmp.c lib/noodles_link.c

build/arm build/host:
	mkdir -p $@

deploy: $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
