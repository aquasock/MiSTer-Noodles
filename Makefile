# MiSTer-Noodles
#
#   make            cross-build the spike for the MiSTer (static, armv7/Cortex-A9)
#   make host       native build for poking at it on the desktop (--fake/--ppm)
#   make deploy HOST=192.168.1.x
#   make sim        Verilator simulation of the RTL engine (CMDQ/BLIT)
#   make clean

CROSS   ?= arm-linux-gnueabihf-
ARMCC   := $(CROSS)gcc
HOSTCC  ?= cc

ARMFLAGS := -march=armv7-a -mtune=cortex-a9 -mfpu=neon -mfloat-abi=hard
CFLAGS   := -std=c99 -O2 -Wall -Wextra -Wno-unused-parameter
LDLIBS   := -lm

ARMBIN      := build/arm/misterpet-spike
ARMTOG      := build/arm/fbterm-toggle
ARMLINK     := build/arm/link-push
ARMSLOTDUMP := build/arm/link-slot-dump
ARMMEMSCAN  := build/arm/mem-scan
HOSTBIN     := build/host/misterpet-spike
HOSTLINK    := build/host/link-push
HOSTSLOTDUMP:= build/host/link-slot-dump
HOSTMEMSCAN := build/host/mem-scan

HOST    ?= mister.local
DEST    ?= /media/fat/pet

VERILATOR ?= verilator
SIM_DIR   := build/sim

SOLID_FILL_SIM    := $(SIM_DIR)/solid_fill/Vengine_dut
DDRAM_ADAPTER_SIM := $(SIM_DIR)/ddram_adapter/Vengine_ddram_dut
BLIT_COPY_SIM     := $(SIM_DIR)/blit_copy/Vengine_copy_dut
LINK_RING_SIM     := $(SIM_DIR)/link_ring/Vlink_ring_dut
LINK_FENCE_SIM    := $(SIM_DIR)/link_fence/Vlink_fence_dut

.PHONY: all host deploy sim clean

all: $(ARMBIN) $(ARMTOG) $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN)

sim: $(SOLID_FILL_SIM) $(DDRAM_ADAPTER_SIM) $(BLIT_COPY_SIM) $(LINK_RING_SIM) $(LINK_FENCE_SIM)
	$(SOLID_FILL_SIM)
	$(DDRAM_ADAPTER_SIM)
	$(BLIT_COPY_SIM)
	$(LINK_RING_SIM)
	$(LINK_FENCE_SIM)

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

$(ARMBIN): src/spike_fb.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $< $(LDLIBS)
	@$(CROSS)size $@ 2>/dev/null || true
	@file $@ 2>/dev/null || true

$(ARMTOG): src/fbterm_toggle.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/link_push.c lib/noodles_link.c

$(ARMSLOTDUMP): tools/link_slot_dump.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMMEMSCAN): tools/mem_scan.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

host: $(HOSTBIN) $(HOSTLINK) $(HOSTSLOTDUMP) $(HOSTMEMSCAN)

$(HOSTBIN): src/spike_fb.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $< $(LDLIBS)

$(HOSTLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/link_push.c lib/noodles_link.c

$(HOSTSLOTDUMP): tools/link_slot_dump.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTMEMSCAN): tools/mem_scan.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

build/arm build/host:
	mkdir -p $@

deploy: $(ARMBIN) $(ARMTOG)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
