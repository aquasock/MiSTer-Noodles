derive_pll_clocks
derive_clock_uncertainty

# Core and board SDRAM use the same clk_sys net (SDR-008).
# No core/SDRAM CDC timing exceptions are required.

# The core PLL's second output is the separate video clock. Its only path
# into clk_sys is FB_VBL, which Noodles.sv passes through a two-flop
# synchronizer, so the two outputs are unrelated for timing.
set_clock_groups -asynchronous \
   -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}] \
   -group [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
