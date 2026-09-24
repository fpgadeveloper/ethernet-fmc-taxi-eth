Modified BSP files
==================

Files under this folder overlay the Vitis install's `embeddedsw` tree: the
Vitis build script (`Vitis/py/build-vitis.py`) copies them into a local
embeddedsw repository in the workspace and fills in the rest of each `src` /
`data` folder from the install.

There are two overlays, applied in this order:

| folder | applies to |
|--------|-----------|
| `EmbeddedSw/` | every target |
| `EmbeddedSw.<arch>/` | only targets of that architecture (`microblaze`, `zynq`, `zynqmp`, `versal`) |

A patch belongs in the per-architecture folder when it changes BSP *metadata*
— anything that feeds what the tools generate — because such a change is
rarely right for every device family. Patches to source or header files that
are compiled the same way everywhere belong in `EmbeddedSw/`.

### ZynqMP FSBL modifications

This project uses a modified ZynqMP FSBL to fix these issues:

* The code used to read the FMC card's EEPROM on ZCU104 has a bug that you can read about here:
https://forums.xilinx.com/t5/Xilinx-Evaluation-Boards/Enabling-VADJ-on-ZCU104/td-p/861259

These files apply to the ZynqMP targets only. A MicroBlaze target such as
`kcu105` has no FSBL (the bitstream and the application ELF are loaded
directly), so `lib/sw_apps/zynqmp_fsbl/` is simply never referenced by its
build — it is inert, not a dependency.

### lwIP modifications

`lwipopts.h.in` of the lwIP 2.2 port gets two changes, both of which apply to
every target (MicroBlaze and ZynqMP alike):

* Software IP/UDP/TCP/ICMP checksums are forced on. The Taxi MAC has no
  checksum offload, but `lwip220.cmake` configures the checksum options from
  whatever Xilinx MACs it finds in the design and would otherwise switch them
  off.
* An `LWIP_HOOK_IP4_ROUTE_SRC` hook, so that with all four Ethernet FMC ports
  on the same subnet lwIP routes replies out of the port whose address the
  connection is bound to instead of the first link-up netif. The hook itself
  lives in the application (`Vitis/common/src/taxi_macif.c`).

#### MicroBlaze only (`EmbeddedSw.microblaze/`)

A MicroBlaze target such as `kcu105` has no Xilinx Ethernet MAC at all — the
four ports are Taxi RGMII MACs, which are block-design module references with
no Xilinx driver — and the stock lwip220 library refuses to build in that
situation. Two files fix that, and they are deliberately **not** applied to the
other architectures, where the (unused) PS GEM is present and the stock
metadata must keep describing it:

* `data/lwip220.yaml` drops the library's `depends:` block. The stock block
  makes an `emacps`, `axiethernet` or `emaclite` instance a hard precondition
  for adding lwip220 to a domain, so on `kcu105` the library is refused with
  *"lwip220 requires at least one ethernet hardware instance to be present"*.
  The block is also what tells the BSP generator which MAC driver instances to
  expose to the library, so dropping it on a board that **does** have a Xilinx
  MAC would change that board's generated `xtopology_g.c` and checksum-offload
  settings — hence the per-architecture scoping.
* `src/CMakeLists.txt` turns the library's own "requires an Ethernet MAC IP
  instance" `FATAL_ERROR` into a status message, and writes an empty
  `xtopology_g.c` when the generator produced none. Each file explains the
  change in full where it is made.

Both are pinned to the `lwip220_v1_3` directory name, so they need revisiting
when the Vitis version bumps the library version.
