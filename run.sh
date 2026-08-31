#!/bin/bash
F4_DETACHED=1 XDG_CONFIG_HOME=/tmp/f4-qt-manual-config F4_QT_HOST_CACHE_DIR=/tmp/f4-qt-manual-cache script -q -e -c './f4 --gui=qt --attached' /dev/null
