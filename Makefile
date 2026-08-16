# AES-128 front-end regression (Icarus Verilog)
#
#   make            run everything
#   make iterative  run one core
#   make wave CORE=ii10   run with VCD dump
#   make mutation   prove the testbenches detect broken RTL
#   make clean

IVERILOG ?= iverilog
VVP      ?= vvp
PYTHON   ?= python
VECTORS  ?= 1000

SHARED := rtl/aes_sbox.v rtl/aes_round.v rtl/aes_key_expand.v
VECFILE := tb/vectors/aes128_vectors.txt

CORES := iterative ii10 pipelined

RTL_iterative := rtl/aes128_iterative.v
RTL_ii10      := rtl/aes128_iterative_ii10.v
RTL_pipelined := rtl/aes128_pipelined.v

TB_iterative := tb/tb_aes128_iterative.v
TB_ii10      := tb/tb_aes128_iterative_ii10.v
TB_pipelined := tb/tb_aes128_pipelined.v

.PHONY: all $(CORES) vectors model mutation wave clean

all: model $(CORES) mutation
	@echo ""
	@echo "=============================================="
	@echo " REGRESSION PASSED"
	@echo "=============================================="

# Golden model KATs + cross-check of the RTL S-box table
model:
	$(PYTHON) model/aes_golden.py --check-sbox rtl/aes_sbox.v

vectors: $(VECFILE)

$(VECFILE): model/aes_golden.py
	@mkdir -p tb/vectors
	$(PYTHON) model/aes_golden.py --gen-vectors $@ -n $(VECTORS)

define CORE_RULE
$(1): sim/$(1).vvp $(VECFILE)
	$(VVP) sim/$(1).vvp

sim/$(1).vvp: $(TB_$(1)) $(RTL_$(1)) $(SHARED)
	@mkdir -p sim
	$(IVERILOG) -g2012 -Wall -o $$@ $(TB_$(1)) $(SHARED) $(RTL_$(1))
endef
$(foreach c,$(CORES),$(eval $(call CORE_RULE,$(c))))

# make wave CORE=ii10  -> sim/tb_aes128_iterative_ii10.vcd
CORE ?= iterative
wave: sim/$(CORE).vvp $(VECFILE)
	$(VVP) sim/$(CORE).vvp +dumpvcd
	@echo "VCD written; open with: gtkwave tb_aes128_*.vcd"

mutation: $(VECFILE)
	$(PYTHON) sim/mutation_test.py

clean:
	rm -f sim/*.vvp sim/*.vcd *.vcd
	rm -rf sim/synth_out
