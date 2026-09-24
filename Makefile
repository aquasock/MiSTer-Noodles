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
HOSTAR  ?= ar
ARMAR   := $(CROSS)ar
TCLSH   ?= tclsh
PREFIX  ?= /usr/local
DESTDIR ?=
SDK_TARGET ?= arm
CPPFLAGS += -Ilib

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
ARMTILECACHE:= build/arm/tile-cache-demo
ARMBLEND    := build/arm/blend-demo
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
HOSTTILECACHE:= build/host/tile-cache-demo
HOSTBLEND   := build/host/blend-demo
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
LINK_CONTROL_SIM  := $(SIM_DIR)/link_control/Vlink_control_dut
PRESENT_SIM       := $(SIM_DIR)/present/Vpresent_dut
BATCH_CMDQ_SIM    := $(SIM_DIR)/cmdq_batch/Vcmdq_batch_dut
SPRITE_BATCH_SIM  := $(SIM_DIR)/sprite_batch/Vengine_sprite_batch_dut
SDRAM_ADAPTER_SIM := $(SIM_DIR)/sdram_adapter/Vsdram_adapter_dut
SDRAM_LOADER_SIM := $(SIM_DIR)/sdram_loader/Vsdram_loader_dut
SPRITE_BATCH_SDRAM_SIM := $(SIM_DIR)/sprite_batch_sdram/Vengine_sprite_batch_sdram_dut
BLEND_PX_SIM      := $(SIM_DIR)/blend_px/Vblend_px
BLIT_BLEND_SIM    := $(SIM_DIR)/blit_blend/Vengine_blend_dut
BLEND_RTL         := rtl/blend_px.sv rtl/blend_walk.sv rtl/blit_blend.sv

.PHONY: all host deploy sim test-host test-timing test-sdk-install sdk sdk-host install-sdk clean

all: sdk $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP) $(ARMSTRESS) $(ARMTILECACHE) $(ARMBLEND) $(ARMPRESENTPROBE)

sdk: build/arm/libnoodles.a build/arm/sdk-smoke
sdk-host: build/host/libnoodles.a build/host/sdk-smoke

build/arm/noodles_link.o: lib/noodles_link.c lib/noodles_link.h lib/noodles_link_internal.h lib/noodles_surface.h | build/arm
	$(ARMCC) $(CPPFLAGS) $(ARMFLAGS) $(CFLAGS) -c $< -o $@

build/host/noodles_link.o: lib/noodles_link.c lib/noodles_link.h lib/noodles_link_internal.h lib/noodles_surface.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

build/arm/noodles_surface.o: lib/noodles_surface.c lib/noodles_surface.h lib/noodles_link.h lib/noodles_link_internal.h | build/arm
	$(ARMCC) $(CPPFLAGS) $(ARMFLAGS) $(CFLAGS) -c $< -o $@

build/host/noodles_surface.o: lib/noodles_surface.c lib/noodles_surface.h lib/noodles_link.h lib/noodles_link_internal.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

build/arm/libnoodles.a: build/arm/noodles_link.o build/arm/noodles_surface.o
	$(ARMAR) rcs $@ $^

build/host/libnoodles.a: build/host/noodles_link.o build/host/noodles_surface.o
	$(HOSTAR) rcs $@ $^

build/arm/sdk-smoke: examples/sdk_smoke.c build/arm/libnoodles.a
	$(ARMCC) $(CPPFLAGS) $(ARMFLAGS) $(CFLAGS) -static -o $@ $< build/arm/libnoodles.a

build/host/sdk-smoke: examples/sdk_smoke.c build/host/libnoodles.a
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ $< build/host/libnoodles.a

install-sdk: build/$(SDK_TARGET)/libnoodles.a
	install -d "$(DESTDIR)$(PREFIX)/lib/pkgconfig" "$(DESTDIR)$(PREFIX)/include"
	install -m 644 build/$(SDK_TARGET)/libnoodles.a "$(DESTDIR)$(PREFIX)/lib/"
	install -m 644 lib/noodles_link.h lib/noodles_surface.h "$(DESTDIR)$(PREFIX)/include/"
	sed 's|@PREFIX@|$(PREFIX)|g' lib/noodles.pc.in > "$(DESTDIR)$(PREFIX)/lib/pkgconfig/noodles.pc"

test-host: $(HOSTLINKTEST) build/host/test-noodles-sdk
	$(HOSTLINKTEST)
	build/host/test-noodles-sdk

build/host/test-noodles-sdk: sim/test_noodles_sdk.c build/host/libnoodles.a
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ $< build/host/libnoodles.a \
		-Wl,--wrap=open -Wl,--wrap=mmap -Wl,--wrap=munmap \
		-Wl,--wrap=clock_gettime -Wl,--wrap=nanosleep

test-timing:
	$(TCLSH) sim/test_report_multicorner.tcl

test-sdk-install:
	HOSTCC="$(HOSTCC)" CROSS="$(CROSS)" sh sim/test_sdk_install.sh

$(HOSTLINKTEST): sim/test_noodles_link.c lib/noodles_link.c lib/noodles_surface.c lib/noodles_link.h lib/noodles_link_internal.h lib/noodles_surface.h
	@mkdir -p $(dir $@)
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ sim/test_noodles_link.c lib/noodles_link.c lib/noodles_surface.c \
		-Wl,--wrap=mmap -Wl,--wrap=munmap

sim: $(SOLID_FILL_SIM) $(DDRAM_ADAPTER_SIM) $(DDRAM_INGRESS_SIM) $(BLIT_COPY_SIM) $(BLIT_COPY64_SIM) $(BLIT_COPY64_PIPELINE_SIM) $(LINK_RING_SIM) $(LINK_FENCE_SIM) $(LINK_CONTROL_SIM) $(PRESENT_SIM) $(BATCH_CMDQ_SIM) $(SPRITE_BATCH_SIM) $(SDRAM_ADAPTER_SIM) $(SDRAM_LOADER_SIM) $(SPRITE_BATCH_SDRAM_SIM) $(BLEND_PX_SIM) $(BLIT_BLEND_SIM)
	$(SOLID_FILL_SIM)
	$(DDRAM_ADAPTER_SIM)
	$(DDRAM_INGRESS_SIM)
	$(BLIT_COPY_SIM)
	$(BLIT_COPY64_SIM)
	$(BLIT_COPY64_PIPELINE_SIM)
	$(LINK_RING_SIM)
	$(LINK_FENCE_SIM)
	$(LINK_CONTROL_SIM)
	$(PRESENT_SIM)
	$(BATCH_CMDQ_SIM)
	$(SPRITE_BATCH_SIM)
	$(SDRAM_ADAPTER_SIM)
	$(SDRAM_LOADER_SIM)
	$(SPRITE_BATCH_SDRAM_SIM)
	$(BLEND_PX_SIM)
	$(BLIT_BLEND_SIM)

$(BLEND_PX_SIM): rtl/blend_px.sv sim/tb_blend_px.cpp sim/blend_ref.h
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module blend_px \
		--Wall --Wno-fatal -O3 \
		rtl/blend_px.sv sim/tb_blend_px.cpp -o $(notdir $@)

$(BLIT_BLEND_SIM): $(BLEND_RTL) rtl/ddram_adapter.sv sim/engine_blend_dut.sv sim/tb_blit_blend.cpp sim/blend_ref.h
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module engine_blend_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME -CFLAGS -std=c++17 \
		$(BLEND_RTL) rtl/ddram_adapter.sv sim/engine_blend_dut.sv sim/tb_blit_blend.cpp -o $(notdir $@)

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

$(LINK_CONTROL_SIM): rtl/link_control.sv sim/link_control_dut.sv sim/tb_link_control.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module link_control_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/link_control.sv sim/link_control_dut.sv sim/tb_link_control.cpp -o $(notdir $@)

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

$(ARMLINK): tools/link_push.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/link_push.c build/arm/libnoodles.a

$(ARMSLOTDUMP): tools/link_slot_dump.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMPRESENTPROBE): tools/present_probe_dump.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMMEMSCAN): tools/mem_scan.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMCOPYPUSH): tools/blit_copy_push.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/blit_copy_push.c build/arm/libnoodles.a

$(ARMFILLPUSH): tools/solid_fill_push.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/solid_fill_push.c build/arm/libnoodles.a

$(ARMKEYPUSH): tools/blit_copy_key_push.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/blit_copy_key_push.c build/arm/libnoodles.a

$(ARMBENCH): tools/bench.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/bench.c build/arm/libnoodles.a

$(ARMPRESENT): tools/present_demo.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/present_demo.c build/arm/libnoodles.a

$(ARMSPRITE): tools/sprite_demo.c build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/sprite_demo.c build/arm/libnoodles.a

$(ARMLOADBMP): tools/load_bmp.c tools/bmp_loader.h build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/load_bmp.c build/arm/libnoodles.a

$(ARMSTRESS): tools/stress_demo.c tools/bmp_loader.h build/arm/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/stress_demo.c build/arm/libnoodles.a

$(ARMTILECACHE): tools/tile_cache_demo.c build/arm/libnoodles.a lib/noodles_link.h lib/noodles_surface.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/tile_cache_demo.c build/arm/libnoodles.a

$(ARMBLEND): tools/blend_demo.c sim/blend_ref.h build/arm/libnoodles.a lib/noodles_link.h lib/noodles_surface.h tools/sdk_helpers.h | build/arm
	$(ARMCC) $(ARMFLAGS) $(CPPFLAGS) $(CFLAGS) -static -o $@ tools/blend_demo.c build/arm/libnoodles.a -lm

host: sdk-host $(HOSTLINK) $(HOSTSLOTDUMP) $(HOSTMEMSCAN) $(HOSTCOPYPUSH) $(HOSTFILLPUSH) $(HOSTKEYPUSH) $(HOSTBENCH) $(HOSTPRESENT) $(HOSTSPRITE) $(HOSTLOADBMP) $(HOSTSTRESS) $(HOSTTILECACHE) $(HOSTBLEND) $(HOSTPRESENTPROBE)

$(HOSTLINK): tools/link_push.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/link_push.c build/host/libnoodles.a

$(HOSTSLOTDUMP): tools/link_slot_dump.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTPRESENTPROBE): tools/present_probe_dump.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTMEMSCAN): tools/mem_scan.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTCOPYPUSH): tools/blit_copy_push.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/blit_copy_push.c build/host/libnoodles.a

$(HOSTFILLPUSH): tools/solid_fill_push.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/solid_fill_push.c build/host/libnoodles.a

$(HOSTKEYPUSH): tools/blit_copy_key_push.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/blit_copy_key_push.c build/host/libnoodles.a

$(HOSTBENCH): tools/bench.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/bench.c build/host/libnoodles.a

$(HOSTPRESENT): tools/present_demo.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/present_demo.c build/host/libnoodles.a

$(HOSTSPRITE): tools/sprite_demo.c build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/sprite_demo.c build/host/libnoodles.a

$(HOSTLOADBMP): tools/load_bmp.c tools/bmp_loader.h build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/load_bmp.c build/host/libnoodles.a

$(HOSTSTRESS): tools/stress_demo.c tools/bmp_loader.h build/host/libnoodles.a lib/noodles_link.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/stress_demo.c build/host/libnoodles.a

$(HOSTTILECACHE): tools/tile_cache_demo.c build/host/libnoodles.a lib/noodles_link.h lib/noodles_surface.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/tile_cache_demo.c build/host/libnoodles.a

$(HOSTBLEND): tools/blend_demo.c sim/blend_ref.h build/host/libnoodles.a lib/noodles_link.h lib/noodles_surface.h tools/sdk_helpers.h | build/host
	$(HOSTCC) $(CPPFLAGS) $(CFLAGS) -o $@ tools/blend_demo.c build/host/libnoodles.a -lm

build/arm build/host:
	mkdir -p $@

deploy: sdk $(ARMLINK) $(ARMSLOTDUMP) $(ARMMEMSCAN) $(ARMCOPYPUSH) $(ARMFILLPUSH) $(ARMKEYPUSH) $(ARMBENCH) $(ARMPRESENT) $(ARMSPRITE) $(ARMLOADBMP) $(ARMSTRESS) $(ARMTILECACHE) $(ARMBLEND) $(ARMPRESENTPROBE)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
