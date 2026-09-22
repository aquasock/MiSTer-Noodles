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

ARMBIN     := build/arm/misterpet-spike
ARMTOG     := build/arm/fbterm-toggle
ARMMARKER  := build/arm/ddram-marker-check
ARMSCAN    := build/arm/ddram-marker-scan
HOSTBIN    := build/host/misterpet-spike
HOSTMARKER := build/host/ddram-marker-check
HOSTSCAN   := build/host/ddram-marker-scan

HOST    ?= mister.local
DEST    ?= /media/fat/pet

VERILATOR ?= verilator
SIM_DIR   := build/sim

SOLID_FILL_SIM    := $(SIM_DIR)/solid_fill/Vengine_dut
DDRAM_ADAPTER_SIM := $(SIM_DIR)/ddram_adapter/Vengine_ddram_dut
MARKER_TEST_SIM   := $(SIM_DIR)/marker_test/Vmarker_test_dut
CMD_TRIGGER_SIM   := $(SIM_DIR)/cmd_trigger/Vcmd_trigger_dut
CMD_COPY_SIM      := $(SIM_DIR)/cmd_copy_trigger/Vcmd_copy_trigger_dut

.PHONY: all host deploy sim clean

all: $(ARMBIN) $(ARMTOG) $(ARMMARKER) $(ARMSCAN)

sim: $(SOLID_FILL_SIM) $(DDRAM_ADAPTER_SIM) $(MARKER_TEST_SIM) $(CMD_TRIGGER_SIM) $(CMD_COPY_SIM)
	$(SOLID_FILL_SIM)
	$(DDRAM_ADAPTER_SIM)
	$(MARKER_TEST_SIM)
	$(CMD_TRIGGER_SIM)
	$(CMD_COPY_SIM)

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

$(MARKER_TEST_SIM): rtl/ddram_marker_test.sv sim/marker_test_dut.sv sim/tb_marker_test.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module marker_test_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/ddram_marker_test.sv sim/marker_test_dut.sv sim/tb_marker_test.cpp -o $(notdir $@)

$(CMD_TRIGGER_SIM): rtl/cmd_test_trigger.sv rtl/cmdq.sv rtl/blit.sv sim/cmd_trigger_dut.sv sim/tb_cmd_trigger.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module cmd_trigger_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmd_test_trigger.sv rtl/cmdq.sv rtl/blit.sv sim/cmd_trigger_dut.sv sim/tb_cmd_trigger.cpp -o $(notdir $@)

$(CMD_COPY_SIM): rtl/cmd_test_trigger.sv rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/ddram_adapter.sv sim/cmd_copy_trigger_dut.sv sim/tb_cmd_copy_trigger.cpp
	@mkdir -p $(dir $@)
	$(VERILATOR) --cc --exe --build --Mdir $(dir $@) --top-module cmd_copy_trigger_dut \
		--Wall --Wno-fatal -Wno-DECLFILENAME \
		rtl/cmd_test_trigger.sv rtl/cmdq.sv rtl/blit.sv rtl/blit_copy.sv rtl/ddram_adapter.sv sim/cmd_copy_trigger_dut.sv sim/tb_cmd_copy_trigger.cpp -o $(notdir $@)

$(ARMBIN): src/spike_fb.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $< $(LDLIBS)
	@$(CROSS)size $@ 2>/dev/null || true
	@file $@ 2>/dev/null || true

$(ARMTOG): src/fbterm_toggle.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMMARKER): tools/ddram_marker_check.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

$(ARMSCAN): tools/ddram_marker_scan.c | build/arm
	$(ARMCC) $(ARMFLAGS) $(CFLAGS) -static -o $@ $<

host: $(HOSTBIN) $(HOSTMARKER) $(HOSTSCAN)

$(HOSTBIN): src/spike_fb.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $< $(LDLIBS)

$(HOSTMARKER): tools/ddram_marker_check.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

$(HOSTSCAN): tools/ddram_marker_scan.c | build/host
	$(HOSTCC) $(CFLAGS) -o $@ $<

build/arm build/host:
	mkdir -p $@

deploy: $(ARMBIN) $(ARMTOG)
	scripts/deploy.sh $(HOST)

clean:
	rm -rf build
