# Die ping-Flags werden gemessen, nicht geraten.
load_libs
export PATH="$MOCK_BIN:$PATH"

# Normalfall: -W funktioniert.
scen ping_lo_rc "0"
assert_eq "$(detect_ping_timeout_flag)" "-W" "iputils-Variante wird erkannt"
assert_eq "$(detect_ping_bind_flag)" "-I" "Interface-Bindung wird erkannt"

# ping funktioniert ueberhaupt nicht: die Erkennung muss das melden,
# damit das Setup Stufe 4 abwaehlen kann, statt falsch positiv zu bestehen.
scen ping_lo_rc "2"
assert_true test ! "$(detect_ping_timeout_flag)" "Ohne funktionierendes ping keine Flags"
detect_ping_timeout_flag >/dev/null 2>&1 && rc=0 || rc=1
assert_eq "$rc" "1" "Die Erkennung muss fehlschlagen, nicht raten"
