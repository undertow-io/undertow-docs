#!/bin/sh
for i in *.dot 
do
dot -Tpng $i > `echo $i | sed s/\.dot/\.png/`
done