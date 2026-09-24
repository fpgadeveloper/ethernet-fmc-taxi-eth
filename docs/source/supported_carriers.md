# Supported carrier boards

## List of supported boards

{% set unique_boards = {} %}
{% for design in data.designs %}
    {% if design.publish %}
        {% if design.board not in unique_boards %}
            {% set _ = unique_boards.update({design.board: {"group": design.group, "link": design.link, "connectors": []}}) %}
        {% endif %}
        {% if design.connector not in unique_boards[design.board]["connectors"] and '&' not in design.connector %}
            {% set _ = unique_boards[design.board]["connectors"].append(design.connector) %}
        {% endif %}
    {% endif %}
{% endfor %}

{% for group in data.groups %}
    {% set boards_in_group = [] %}
    {% for name, board in unique_boards.items() %}
        {% if board.group == group.label %}
            {% set _ = boards_in_group.append(board) %}
        {% endif %}
    {% endfor %}

    {% if boards_in_group | length > 0 %}
### {{ group.name }} boards

| Carrier board        | Supported FMC connector(s)    |
|---------------------|--------------|
{% for name,board in unique_boards.items() %}{% if board.group == group.label %}| [{{ name }}]({{ board.link }}) | {% for connector in board.connectors %}{{ connector }} {% endfor %} |
{% endif %}{% endfor %}
{% endif %}
{% endfor %}

## Unlisted boards

The Taxi MAC design is transceiver-free (the RGMII PHYs use the LA pairs of the FMC connector)
and uses only the LPC pins of the connector, so it can be ported to any carrier whose LPC or HPC
connector mates with the [Ethernet FMC] at a VADJ the card supports, and whose device has a hard
processor or room for a soft one. If you need more information on whether the Ethernet FMC is
compatible with a carrier that is not listed above, please first check the
[compatibility list]. If the carrier is not listed there, please [contact Opsero],
provide us with the pinout of your carrier and we'll be happy to check compatibility and generate a
Vivado constraints file for you.

## Board specific notes

### ZCU104

* The ZCU104's LPC connector runs VADJ between 1.2V and 1.8V, so only the **1.8V** versions of the
  [Ethernet FMC] (OP031-1V8) and [Robust Ethernet FMC] (OP041-1V8) can be used on this board. The
  device's HP I/Os do not support 2.5V levels.
* **VADJ is enabled by the FSBL, which needs a patch on this board.** The 2025.2 Zynq UltraScale+
  FSBL reads the VADJ record from the wrong EEPROM (the board's own at 0x54, on the wrong I2C mux
  channel, rather than the FMC's at 0x50) and reads too few bytes to reach the VADJ field, so it
  never powers the FMC. Both flows in this repository carry the fix: the Yocto BSP applies
  `Yocto/bsp/zcu104/.../zcu104_vadj_fsbl.patch` to `fsbl-firmware`, and the standalone flow builds
  its platform from the patched FSBL sources in `EmbeddedSw/lib/sw_apps/zynqmp_fsbl/` (the build
  scripts register that directory as a local embedded-software repository), so its `BOOT.BIN`
  powers the FMC too. If the PHYs never link up (MDIO reads return all ones), an unpatched FSBL is
  the first thing to check.
* The board's own RJ45 (PS GEM3, TI DP83867 PHY) is kept in the design and the Linux image, so the
  board can be reached over the LAN independently of the Ethernet FMC ports.
* Boot mode is set by DIP switch SW6: SD card = `1000` (1 = ON, 2 = OFF, 3 = OFF, 4 = OFF),
  JTAG = `1111`.

### KCU105

* The design is built on the **HPC** connector of the KCU105. The [Ethernet FMC] is an LPC-class
  card, so it mates with the HPC slot and uses only its LPC pins.
* VADJ on the KCU105 is set by the board's own system controller (1.5V to 1.8V), **not** by a
  first-stage boot loader as on the ZCU104 — there is no FSBL and no VADJ patch to apply here.
  The FMC is powered as soon as the board is. Because the board's VADJ never reaches 2.5V, only
  the **1.8V** versions of the [Ethernet FMC] (OP031-1V8) and [Robust Ethernet FMC] (OP041-1V8)
  can be used.
* FPGA configuration mode is set by DIP switch **SW15**: JTAG = switch 5 **OFF**, switch 6
  **ON** (switches 1 to 4 are don't-care). That is the mode this design is loaded in.
* The KCU105 target is **baremetal only** — the standalone echo server, loaded over JTAG. There
  is no embedded Linux flow for it (see [MicroBlaze design differences](#microblaze-design-differences)).
* The KCU105's XCKU040 is not supported by the Vivado ML *Standard* Edition, so building this
  target needs **Vivado Enterprise** (a 30-day evaluation license is available from AMD). That is
  a property of the device, not of the design — the design itself uses no licensed IP.

## MicroBlaze design differences

On a board with no hard processor — the KCU105 is the first such target — the design brings its
own processor subsystem instead of using a PS. What the Zynq UltraScale+ PS provides for free is
built in programmable logic:

* a **MicroBlaze** soft processor running at 100 MHz, with local memory for the vectors and its
  code and data in DDR4;
* the **DDR4 memory controller (MIG)** for the board's 2 GB of DDR4, which the four AXI DMAs and
  the application share;
* an **AXI INTC** interrupt controller (the DMA and timer interrupts have no PS GIC to go to),
  an **AXI Timer** for the lwIP tick, and an **AXI UART16550** for the console;
* the RGMII receive **IDELAYCTRL** reference clock, which on this board comes from the DDR4
  controller's 300 MHz user-interface clock rather than from a third clocking-wizard output
  (deriving 125 MHz, 125 MHz at 90 degrees *and* 300 MHz from the FMC reference would need a
  1500 MHz VCO, above the limit of the Kintex UltraScale -2 speed grade — the memory
  controller's user clock is already exactly 300 MHz);
* **no FSBL**: nothing has to run before the application. The bitstream configures the FPGA and
  the ELF is loaded straight into DDR4 over JTAG.

Everything above the processor is the same design: four `taxi_rgmii_mac` cells, four AXI DMAs,
the same lwIP echo server sources. The console baud rate differs — the KCU105's UART16550 runs at
**9600 baud**, against 115200 on the ZCU104's PS UART.

The receive-side IDELAY values are board-specific, because they compensate the trace lengths
between the FMC connector and the FPGA banks. On the KCU105 they are set per port by the
`rx_idelay_ps` list at the top of `Vivado/src/bd/bd_mb-us.tcl`, which the block design applies to
each MAC cell as `RX_IDELAY_PS`.
The validated values are `1100` ps on all four ports (setup margin about +0.25 ns and hold
about +0.03 ns at signoff); every KCU105 HPC receive clock sits on a clock-capable pin, so
no port needs the non-dedicated clock routing that ports 1 and 3 need on the ZCU104.

[contact Opsero]: https://opsero.com/contact-us
[compatibility list]: https://ethernetfmc.com/documentation/compatiblility.html
[Ethernet FMC]: https://docs.opsero.com/op031/datasheet/overview/
[Robust Ethernet FMC]: https://docs.opsero.com/op041/datasheet/overview/
