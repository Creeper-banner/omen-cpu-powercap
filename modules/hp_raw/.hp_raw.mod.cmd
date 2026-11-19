savedcmd_hp_raw.mod := printf '%s\n'   hp_raw.o | awk '!x[$$0]++ { print("./"$$0) }' > hp_raw.mod
