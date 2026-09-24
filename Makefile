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
TCLSH   ?= tclsh

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
ARMSTRESS   := build/arm/stress-demo
ARMPRESENTPROBE := build/arm/present-probe-dump
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
HOSTSTRESS  := build/host/stress-demo
HOSTPRESENTPROBE := build/host/present-probe-dump
HOSTLINKTEST := build/host/test-noodles-link

HOST    ?= mister.local
DEST    ?= /media/fat/pet

VERILATOR ?= verilator
SIM_DIR   := build/sim

SOLID_FILL_SIM    := $(SIM_DIR)/solid_fill/Vengine_dut
DDRAM_ADAPTER_SIM := $(SIM_DIR)/ddram_adapter/Vengine_ddram_dut
DDRAM_INGRESS_SIM := $(SIM_DIR)/ddram_ingress/Vddram_adapter
BLIT_COPY_SIM     := $(SIM_DIR)/blit_copy/Vengine_copy_dut
BLIT_COPY64_SIM   := $(SIM_DIR)/blit_copy64/Vengine_copy64_dut
BLIT_COPY64_PIPELINE_SIM := $(SIM_DIR)/blit_copy64_pipeline/Vblit_copy64
LINK_RING_SIM     := $(SIM_DIR)/link_ring/Vlink_ring_dut
LINK_FENCE_SIM    := $(SIM_DIR)/link_fence/Vlink_fence_dut
PRESENT_SIM       := $(SIM_DIR)/present/Vpresent_dut
BATCH_CMDQ_SIM    := $(SIM_DIR)/cmdq_batch/Vcmdq_batch_dut
SPRITE_BATCH_SIM  := $(SIM_DIR)/sprite_batch/Vengine_sprite_batch_dut
SDRAM_ADAPTER_SIM := $(SIM_DIR)/sdram_adapter/Vsdram_adapter_dut
SDRAM_LOADER_SIM := $(SIM_DIR)/sdram_loader/Vsdram_loader_dut
SPRITE_BATCH_SDRAM_SIM := $(SIM_DIR)/sprite_batch_sdram/Vengine_sprite_batch_sdram_dut

.PHONY: all host deploy sim test-host test-timing clean

all: $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP) $(ARMSTRESS) $(ARMPRESENTPROBE)

test-host: $(HOSTLINKTEST)
	$(HOSTLINKTEST)

test-timing:
	$(TCLSH) sim/test_report_multicorner.tcl

$(HOSTLINKTEST): sim/test_noodles_link.c lib/noodles_link.c lib/noodles_link.h
	@mkdir -p $(dir $@)
	$(HOSTCC) $(CFLAGS) -o $@ sim/test_noodles_link.c lib/noodles_link.c \
		-Wl,--wrap=mmap -Wl,--wrap=munmap

sim: $(SOLID_FILL_SIM) $(DDRAM_ADAPTER_SIM) $(DDRAM_INGRESS_SIM) $(BLIT_COPY_SIM) $(BLIT_COPY64_SIM) $(BLIT_COPY64_PIPELINE_SIM) $(LINK_RING_SIM) $(LINK_FENCE_SIM) $(PRESENT_SIM) $(BATCH_CMDQ_SIM) $(SPRITE_BATCH_SIM) $(SDRAM_ADAPTER_SIM) $(SDRAM_LOADER_SIM) $(SPRITE_BATCH_SDRAM_SIM)
	$(SOLID_FILL_SIM)
	$(DDRAM_ADAPTER_SIM)
	$(DDRAM_INGRESS_SIM)
	$(BLIT_COPY_SIM)
	$(BLIT_COPY64_SIM)
	$(BLIT_COPY64_PIPELINE_SIM)
	$(LINK_RING_SIM)
	$(LINK_FENCE_SIM)
	$(PRESENT_SIM)
	$(BATCH_CMDQ_SIM)
	$(SPRITE_BATCH_SIM)
	$(SDRAM_ADAPTER_SIM)
	$(SDRAM_LOADER_SIM)
	$(SPRITE_BATCH_SDRAM_SIM)

$(BATCH_CMDQ_SIM): rtl/cmdq.sv sim/cmdq_batch_dut.sv sim/tb_cmdq_batch.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module cmdq_batch_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv sim/cmdq_batch_dut.sv sim/tb_cmdq_batch.cpp -o $(notdir $@)

$(SOLID_FILL_SIM): rtl/cmdq.sv rtl/blit.sv sim/engine_dut.sv sim/tb_solid_fill.cpp lib/noodles_link.h
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv sim/engine_dut.sv sim/tb_solid_fill.cpp -o $(notdir $@)

$(DDRAM_ADAPTER_SIM): rtl/cmdq.sv rtl/blit.sv rtl/ddram_adapter.sv sim/engine_ddram_dut.sv sim/tb_ddram_adapter.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_ddram_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv rtl/ddram_adapter.sv sim/engine_ddram_dut.sv sim/tb_ddram_adapter.cpp -o $(notdir $@)

$(DDRAM_INGRESS_SIM): rtl/ddram_adapter.sv sim/tb_ddram_ingress.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module ddram_adapter \
		--Wall --Wno-fatal \
		rtl/ddram_adapter.sv sim/tb_ddram_ingress.cpp -o $(notdir $@)

$(BLIT_COPY_SIM): rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/blit_copy64.sv rtl/sprite_batch.sv rtl/ddram_adapter.sv sim/engine_copy_dut.sv sim/tb_blit_copy.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_copy_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/blit_copy64.sv rtl/sprite_batch.sv rtl/ddram_adapter.sv sim/engine_copy_dut.sv sim/tb_blit_copy.cpp -o $(notdir $@)

$(BLIT_COPY64_SIM): rtl/blit_copy64.sv rtl/ddram_adapter.sv sim/engine_copy64_dut.sv sim/tb_blit_copy64.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_copy64_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/blit_copy64.sv rtl/ddram_adapter.sv sim/engine_copy64_dut.sv sim/tb_blit_copy64.cpp -o $(notdir $@)

$(BLIT_COPY64_PIPELINE_SIM): rtl/blit_copy64.sv sim/tb_blit_copy64_pipeline.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module blit_copy64 \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/blit_copy64.sv sim/tb_blit_copy64_pipeline.cpp -o $(notdir $@)

$(SPRITE_BATCH_SIM): rtl/sprite_batch.sv rtl/blit_copy64.sv rtl/ddram_adapter.sv sim/engine_sprite_batch_dut.sv sim/tb_sprite_batch.cpp lib/noodles_link.h
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_sprite_batch_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/sprite_batch.sv rtl/blit_copy64.sv rtl/ddram_adapter.sv sim/engine_sprite_batch_dut.sv sim/tb_sprite_batch.cpp -o $(notdir $@)

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

$(SDRAM_ADAPTER_SIM): rtl/sdram_adapter.sv sim/sdram_adapter_dut.sv sim/tb_sdram_adapter.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module sdram_adapter_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/sdram_adapter.sv sim/sdram_adapter_dut.sv sim/tb_sdram_adapter.cpp -o $(notdir $@)

$(SDRAM_LOADER_SIM): rtl/sdram_page_buffer.sv rtl/sdram_loader.sv sim/sdram_loader_dut.sv sim/tb_sdram_loader.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module sdram_loader_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/sdram_page_buffer.sv rtl/sdram_loader.sv sim/sdram_loader_dut.sv sim/tb_sdram_loader.cpp -o $(notdir $@)

$(SPRITE_BATCH_SDRAM_SIM): rtl/sprite_batch.sv rtl/blit_copy64.sv rtl/ddram_adapter.sv rtl/sdram_adapter.sv sim/sdram_adapter_dut.sv sim/engine_sprite_batch_sdram_dut.sv sim/tb_sprite_batch_sdram.cpp lib/noodles_link.h
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_sprite_batch_sdram_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/sprite_batch.sv rtl/blit_copy64.sv rtl/ddram_adapter.sv rtl/sdram_adapter.sv sim/sdram_adapter_dut.sv sim/engine_sprite_batch_sdram_dut.sv sim/tb_sprite_batch_sdram.cpp -o $(notdir $@)

$(ARMLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/link_push.c lib/noodles_link.c

$(ARMSLOTDUMP): tools/link_slot_dump.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMPRESENTPROBE): tools/present_probe_dump.c | build/arm
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

$(ARMLOADBMP): tools/load_bmp.c tools/bmp_loader.h lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/load_bmp.c lib/noodles_link.c

$(ARMSTRESS): tools/stress_demo.c tools/bmp_loader.h lib/noodles_link.c lib/noodles_link.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ tools/stress_demo.c lib/noodles_link.c

host: $(HOSTLINK) $(HOSTSLOTDUMP) $(HOSTMEMSCAN) $(HOSTCOPYPUSH) $(HOSTFILLPUSH) $(HOSTKEYPUSH) $(HOSTBENCH) $(HOSTPRESENT) $(HOSTSPRITE) $(HOSTLOADBMP) $(HOSTSTRESS) $(HOSTPRESENTPROBE)

$(HOSTLINK): tools/link_push.c lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/link_push.c lib/noodles_link.c

$(HOSTSLOTDUMP): tools/link_slot_dump.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTPRESENTPROBE): tools/present_probe_dump.c | build/host
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

$(HOSTLOADBMP): tools/load_bmp.c tools/bmp_loader.h lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/load_bmp.c lib/noodles_link.c

$(HOSTSTRESS): tools/stress_demo.c tools/bmp_loader.h lib/noodles_link.c lib/noodles_link.h | build/host
	$(HOSTCC) $(CFLAGS) -o $@ tools/stress_demo.c lib/noodles_link.c

build/arm build/host:
	mkdir -p $@

deploy: $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP) $(ARMSTRESS) $(ARMPRESENTPROBE)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
