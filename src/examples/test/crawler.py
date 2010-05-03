#!/usr/bin/python

import sys; sys.path += ['src/examples/test']
import runutil, math, os

for n in runutil.parallelism:
  os.system('mkdir -p logs.%d' % n)
  os.system('rm logs.%d/*' % n)
  cmd = ' '.join(['mpirun',
                  '-hostfile fast_hostfile',
                  '-bynode',
                  '-display-map',
                  '-n %d' % (1 + n),
                  'bin/release/examples/dsm-crawler',
                  '--log_prefix=false',
                  '--crawler_runtime=120'])
  
  runutil.run_command(cmd, n, logfile_name='Crawler')
