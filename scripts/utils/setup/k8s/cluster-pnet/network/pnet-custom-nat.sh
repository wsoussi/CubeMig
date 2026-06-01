#!/usr/bin/env bash
set -euo pipefail

sysctl -w net.ipv4.ip_forward=1

# PNET -> cluster1 east-west gateway over wg1 from core-master1
iptables -t nat -C POSTROUTING -d 10.0.0.50/32 -o wg1 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -d 10.0.0.50/32 -o wg1 -j MASQUERADE

# PNET subnet -> registry/checkpoint host over wg0 from core-master1
iptables -t nat -C POSTROUTING -s 10.1.6.0/24 -d 10.10.10.1/32 -o wg0 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 10.1.6.0/24 -d 10.10.10.1/32 -o wg0 -j MASQUERADE