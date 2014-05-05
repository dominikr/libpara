#!/bin/sh

. ./libpara.sh || exit 3

foo(){
	sleep 2
	echo $1
}

for i in 1 2 3 4 5 6 7 8 9 10; do
	para foo $i
done

