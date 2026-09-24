# Revision History

## 2025.2 — initial release (2026-09)

First release of the Taxi Ethernet reference designs for the Ethernet FMC.

* Built for Vivado / Vitis 2025.2 and the AMD Yocto / EDF 2025.2 Linux flow
* Targets: ZCU104 (LPC connector, four ports) and KCU105 (HPC connector, four ports, MicroBlaze
  soft processor, standalone only — bitstream + ELF loaded over JTAG, no `BOOT.BIN`)
* Hardware: four Taxi 1G RGMII MACs (`taxi_rgmii_mac` module reference: Taxi MAC + Taxi MDIO
  master + AXI-Lite register file) paired with AXI DMAs; the Taxi transport library is a git
  submodule (`submodules/taxi`, CERN-OHL-S-2.0); no separately-licensed AMD IP
* MicroBlaze block design (`Vivado/src/bd/bd_mb-us.tcl`) for carriers without a hard processor:
  MicroBlaze at 100 MHz, DDR4 MIG, AXI INTC, AXI Timer and AXI UART16550 (9600 baud), with the
  RGMII IDELAYCTRL reference taken from the DDR4 controller's 300 MHz `ui` clock
* Standalone: lwIP echo server on all four ports through a custom lwIP network interface for the
  Taxi MAC + AXI DMA (Vitis Unified IDE Python flow, `Vitis/py/build-vitis.py`)
* Linux: Yocto / EDF image with the out-of-tree `taxi_mac` network driver (`Linux/taxi-mac`) and
  the `taxi-eth-test` self-test; the MACHINE is generated from the Vivado XSA via
  `gen-machineconf parse-sdt`, and the PHY wiring is supplied by the `ports-0123` port-config
  overlay layer
* ZCU104 FSBL VADJ patch applied in the Yocto BSP (the stock 2025.2 FSBL never powers the FMC)
* Cross-platform build runner (`build.py` / `build.sh` / `build.bat`) only — no Makefiles, no
  PetaLinux flow
