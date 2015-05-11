#!/bin/sh

mvn clean install
cd target
unzip undertow-docs*.zip
rsync -rv  --protocol=28 undertow-docs* undertow@filemgmt.jboss.org:/www_htdocs/undertow/undertow-docs



