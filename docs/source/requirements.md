# Requirements

In order to test this design on hardware, you will need the following:

* Vivado 2025.2
* Vitis 2025.2
* A native Linux machine (Ubuntu 22.04 / 24.04) to build the Yocto / EDF Linux image — see
  [Yocto](yocto.md#requirements)
* [Ethernet FMC] or [Robust Ethernet FMC] — the 1.8V version (OP031-1V8 / OP041-1V8) for the
  carrier boards listed below, whose FMC connectors run VADJ at 1.8V
* One of the supported carrier boards listed below

No IP license is needed. The Ethernet MAC is the open-source Taxi core, and the remaining IP in the
block design (Zynq UltraScale+ PS, AXI DMA, SmartConnect, clocking wizard, processor system
reset, IDELAYCTRL) ships with Vivado under the tool license.

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

For list of the target designs showing the number of ports supported, refer to the build instructions.

[Ethernet FMC]: https://docs.opsero.com/op031/datasheet/overview/
[Robust Ethernet FMC]: https://docs.opsero.com/op041/datasheet/overview/
