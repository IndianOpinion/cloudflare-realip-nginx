# Shared by the shims: pick the next value of a space separated sequence held
# in an environment variable. The last value repeats once the list runs out.
seq_next() { # name default
	local name=$1 default=$2 list n
	local -a vals=()
	list=${!name:-$default}
	read -r -a vals <<<"$list"
	n=$(cat "$SHIM_DIR/$name.count" 2>/dev/null || echo 0)
	n=$((n + 1))
	echo "$n" >"$SHIM_DIR/$name.count"
	if ((n > ${#vals[@]})); then
		n=${#vals[@]}
	fi
	printf '%s' "${vals[n - 1]}"
}
