derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ---------------------------------------------------------------------------
# Clock-domain-crossing constraints for sdram_cdc (clk_sys <-> clk_sdram).
#
# Both clocks come from the same PLL/VCO, so TimeQuest times paths between
# them synchronously. With clk_sys=20MHz and clk_sdram=100MHz the clean 1:5
# ratio happened to yield a comfortable 10ns setup relationship, which masked
# the fact that these crossings were never constrained. At other ratios (e.g.
# 65MHz vs 100MHz) the edges beat against each other and the worst-case
# relationship collapses to <1ns, which no real logic can ever meet.
#
# Every clk_sys<->clk_sdram path in this design goes through an sdram_cdc
# instance, which uses a toggle + 2FF-synchronizer handshake (rtl/sdram_cdc.sv):
#   - the toggle bits are metastability-hardened by the 2FF synchronizers,
#     so the crossing into the first sync stage is a false path
#   - the address/data payloads are quasi-static: captured in the source
#     domain and held stable until the synchronized toggle has propagated
#     (>=2 destination cycles), so they only need a bounded physical delay
#     rather than a single-cycle setup relationship
# ---------------------------------------------------------------------------

set_false_path \
    -from [get_registers {*sdram_cdc*req_toggle_a}] \
    -to   [get_registers {*sdram_cdc*req_toggle_b_sync[0]}]
set_false_path \
    -from [get_registers {*sdram_cdc*resp_toggle_b}] \
    -to   [get_registers {*sdram_cdc*resp_toggle_a_sync[0]}]

set_max_delay \
    -from [get_registers {*sdram_cdc*addr_captured_a[*]}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] 10.000
set_min_delay \
    -from [get_registers {*sdram_cdc*addr_captured_a[*]}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}] 0.000

set_max_delay \
    -from [get_registers {*sdram_cdc*data_captured_b[*]}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 10.000
set_min_delay \
    -from [get_registers {*sdram_cdc*data_captured_b[*]}] \
    -to   [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] 0.000
