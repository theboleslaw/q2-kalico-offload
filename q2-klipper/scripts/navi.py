#!/usr/bin/env python3
"""Mainsail sidebar links (.theme/navi.json): the Box page and the selected Q2 Klipper components.

Usage: navi.py <components> <host-ip> <web-port>
"""
import json
import sys

# Material Design Icons paths (pictogrammers.com, Apache-2.0)
ICON_WATER = ("M12,20A6,6 0 0,1 6,14C6,10 12,3.25 12,3.25C12,3.25 18,10 18,14A6,6 0 0,1 12,20Z")
ICON_SPOOL = ("M12,2A10,10 0 0,0 2,12A10,10 0 0,0 12,22A10,10 0 0,0 22,12A10,10 0 0,0 12,2"
              "M12,4A8,8 0 0,1 20,12A8,8 0 0,1 12,20A8,8 0 0,1 4,12A8,8 0 0,1 12,4"
              "M12,9A3,3 0 0,0 9,12A3,3 0 0,0 12,15A3,3 0 0,0 15,12A3,3 0 0,0 12,9Z")


def main():
    components = set(sys.argv[1].split(','))
    host, web_port = sys.argv[2], sys.argv[3]
    base = "http://%s" % host
    # The Box page and the web clients are served by the same nginx.
    port = "" if web_port == "80" else ":%s" % web_port
    links = [{"title": "Box drying", "href": "%s%s/box/" % (base, port), "icon": ICON_WATER}]
    if 'spoolman' in components:
        links.append({"title": "Spoolman", "href": "%s:7912/" % base, "icon": ICON_SPOOL})
    for i, link in enumerate(links):
        link.update(target="_blank", position=85 + i)
    json.dump(links, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == '__main__':
    main()
