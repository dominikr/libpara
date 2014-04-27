#!/bin/bash
PARA_DEBUG=0
__para_debug(){
	if [ "$PARA_DEBUG" = 1 ]; then
		echo $*
	fi
}

__para_fifo_reader(){
	local COMMAND
	mkfifo -m 600 "$PARA_FIFO"
	while true; do
		while read COMMAND; do
			__para_exec $COMMAND
			if [ "$COMMAND" = "DONE" ]; then
				break 2
			fi
		done < "$PARA_FIFO"
		__para_debug "fifo_reader restart"
	done
	wait
}

# this is the para autoinitializer. "para" gets overwritten by the
# real function as soon as we call para_init
para(){
	para_init simple
	para $@
}

para_init(){
	PARA_DIR=$(mktemp -d)
	PARA_COUNT=0
	PARA_RUNNING=0
	PARA_LAST_SHOWN=1
	PARA_DONE_LOCK=''
	PARA_FIFO_PID=''
	PARA_ASYNC_PID=''

	PARA_INORDER=0
	PARA_AUTOSHOW=0
	PARA_AUTOCLEAN=0
	PARA_FIFO=0
	PARA_MAX=''
	PARA_SINGLE=''

	while [ "$#" -gt 0 ]; do
		case "$1" in
			simple)
				PARA_INORDER=1
				PARA_AUTOSHOW=1
				PARA_AUTOCLEAN=1
				PARA_FIFO=''
				;;
			inorder)
				PARA_INORDER=1
				;;
			outoforder)
				PARA_INORDER=''
				;;
			noautoclean*)
				PARA_AUTOCLEAN=''
				;;
			autoclean*)
				PARA_AUTOCLEAN=1
				;;
			async|fifo)
				PARA_FIFO=1	
				;;
			noautoshow)
				PARA_AUTOSHOW=''
				;;
			autoshow)
				PARA_AUTOSHOW=1
				;;
			[0-9]*)
				PARA_MAX=$1
				;;
			*)
				echo "Unknown option \"$1\"" 1>&2
				exit 2
		esac
		shift
	done

	if [ "$PARA_AUTOCLEAN" ]; then
		# can't use pipe:
		# pipe opens a subshell
		# traps are cleared in subshell
		trap > "$PARA_DIR/trap"
		if grep -qE "(EXIT|INT|TERM)$" "$PARA_DIR/trap"; then
			echo "ERROR: Can't enable autoclean, traps already set" 1>&2
			grep -E "(EXIT|INT|TERM)$" "$PARA_DIR/trap" 1>&2
			exit 2
		else
			trap 'para_cleanup' EXIT
			trap 'para_abort' INT
			trap 'para_abort' TERM
		fi
	fi

	if [ ! "$PARA_MAX" ]; then
		PARA_MAX=$(nproc)
	fi

	if [ "$PARA_MAX" = "0" ]; then
		PARA_FIFO=''
		PARA_SINGLE=1
		if [ "$PARA_AUTOSHOW" ]; then
			PARA_AUTOSHOW=''
			# simple 0 reverts to this null function
			para(){ $@; }
		else
			para(){ __para_single $@; }
		fi
	elif [ "$PARA_FIFO" ]; then
		PARA_FIFO="$PARA_DIR/fifo"
		eval 'para(){ echo "$@" > '$PARA_FIFO'; }'
		__para_fifo_reader &
		PARA_FIFO_PID=$!
	else
		PARA_FIFO=''
		para(){ __para_exec $@; }
	fi

	if [ "$PARA_AUTOSHOW" ]; then
		para_show_async
	fi
	
	__para_debug "INIT ac$PARA_AUTOCLEAN max$PARA_MAX"
}

# show new program outputs, nonblocking
para_show(){
	if [ "$PARA_INORDER" ]; then
		local LIST=''
		while [ -e "$PARA_DIR/$PARA_LAST_SHOWN.done" ]; do
			LIST="$LIST $PARA_DIR/$PARA_LAST_SHOWN.done"
			PARA_LAST_SHOWN=$(( PARA_LAST_SHOWN + 1 ))
		done
		[ "$LIST" = "" ] && return
		cat $LIST
		rm $LIST

	else
		set -- $PARA_DIR/*.done
		# globbed anything?
		if [ "$1" = "$PARA_DIR/*.done" ]; then
			return
		fi
		if [ "$#" -gt 0 ]; then
			cat $@
			rm $@
			PARA_LAST_SHOWN=$(( PARA_LAST_SHOWN + $# ))
		fi
	fi
}

para_show_async(){
	para_show_all &
	PARA_ASYNC_PID=$!
}

# show all program outputs, blocking
para_show_all(){
	while true; do
		para_show
		sleep 0.1
		if [ "${PARA_DONE_COUNT-}" ]; then
			if [ "$PARA_LAST_SHOWN" -ge "$PARA_DONE_COUNT" ]; then
				__para_debug "SHOW END $PARA_LAST_SHOWN $PARA_DONE_COUNT"
				return 0
			fi
		elif [ -e "$PARA_DIR/COUNT" ]; then
			read PARA_DONE_COUNT < "$PARA_DIR/COUNT"
		fi

	done
}

# signal that no more new tasks will follow
para_done(){
	# FIFO gets closed after done, so we install a lock
	[ "$PARA_DONE_LOCK" ] && return
	PARA_DONE_LOCK=1
	# pseudomode 'single' does not need a done command
	[ "$PARA_SINGLE" ] && return
	para DONE
}

# exit, as fast as possible
para_abort(){
	[ "$PARA_FIFO_PID" ] && kill "$PARA_FIFO_PID"
	[ "$PARA_ASYNC_PID" ] && kill "$PARA_ASYNC_PID"
	para_cleanup(){ :; }
	[ "${PARA_DIR-}" ] && rm -rf "${PARA_DIR}"
	exit 
}

# wait for procs, clean up tmpdir
para_cleanup(){
	__para_debug "para_cleanup"
	para_done
	wait
	[ "${PARA_DIR-}" ] && rm -rf "${PARA_DIR}"
}

__para_running(){
	set -- $PARA_DIR/*.run
	if [ "$1" = "$PARA_DIR/*.run" ]; then
		PARA_RUNNING=0
	else
		PARA_RUNNING=$#
	fi
}

__para_single(){
	PARA_COUNT=$(( PARA_COUNT + 1 ))
	local -r PARA_FILE="$PARA_DIR/$PARA_COUNT"
	local COMMAND="$*"

	if [ "$COMMAND" = "DONE" ]; then
		__para_debug "PARA_FINAL_COUNT $PARA_COUNT"
		echo "$PARA_COUNT" > "$PARA_DIR/COUNT"
		return
	fi

	$COMMAND > $PARA_FILE.run; mv $PARA_FILE.run $PARA_FILE.done
}

__para_exec(){
	#set -x
	PARA_COUNT=$(( PARA_COUNT + 1 ))
	local PARA_FILE="$PARA_DIR/$PARA_COUNT"
	local COMMAND="$*"

	if [ "$COMMAND" = "DONE" ]; then
		__para_debug "PARA_FINAL_COUNT $PARA_COUNT"
		echo "$PARA_COUNT" > "$PARA_DIR/COUNT"
		return
	fi

	__para_running
	while [ "$PARA_RUNNING" -gt "$PARA_MAX" ]; do
		sleep 0.1
		__para_running
	done
	
	( $COMMAND > $PARA_FILE.run; mv $PARA_FILE.run $PARA_FILE.done 2>/dev/null ) &
}
