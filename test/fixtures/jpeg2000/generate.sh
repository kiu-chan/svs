#!/bin/sh
# Regenerates the JPEG2000 conformance fixtures from the source images here
# with OpenJPEG's opj_compress (e.g. `brew install openjpeg`). Each case
# exercises a different part of the codestream; see
# test/jpeg2000/j2k_conformance_test.dart for how they're checked.
set -e
cd "$(dirname "$0")"
c() { name=$1; shift; opj_compress "$@" -o "$name.j2k" > /dev/null || { echo "failed: $name" >&2; exit 1; }; }
c lossless -i source.ppm
c lossy -i source.ppm -r 20
c lossy_psnr -i source.ppm -I -q 30,40
c layers -i source.ppm -r 80,40,10,1
c rlcp -i source.ppm -r 40,10 -p RLCP
c rpcl_precincts -i source.ppm -r 40,10 -p RPCL -c [16,16],[8,8],[4,4] -n 4
c pcrl_precincts -i source.ppm -p PCRL -c [16,16],[8,8] -n 4
c cprl_precincts -i source.ppm -r 30,5 -p CPRL -c [16,8],[8,16] -n 4
c codeblocks_16 -i source.ppm -b 16,16
c codeblocks_32x8 -i source.ppm -r 15 -b 32,8
c bypass -i source.ppm -M 1
c bypass_lossy -i source.ppm -M 1 -r 10,3
c reset -i source.ppm -M 2
c termall -i source.ppm -M 4 -r 20,5
c vertically_causal -i source.ppm -M 8
c predictable_termination -i source.ppm -M 16
c segmentation_symbols -i source.ppm -M 32
c all_modes -i source.ppm -M 63 -r 20,4
c all_modes_lossless -i source.ppm -M 63
c sop_eph -i source.ppm -SOP -EPH -r 20,5
c tiles -i source.ppm -t 24,20 -n 3
c tiles_offsets -i source.ppm -t 20,16 -T 3,5 -d 7,11 -r 20 -n 3
c tile_parts_resolution -i source.ppm -t 32,32 -TP R -r 30,8 -n 4
c tile_parts_layer -i source.ppm -t 32,32 -TP L -r 30,8 -n 4
c poc -i source.ppm -r 30,10,3 -POC T0=0,0,3,2,3,CPRL/T0=0,0,3,6,3,LRCP
c roi -i source.ppm -ROI c=0,U=6
c roi_lossy -i source.ppm -ROI c=1,U=4 -r 20
c gray -i source_gray.pgm
c gray_lossy -i source_gray.pgm -r 12
c gray16 -i source_gray16.pgm -n 4
c gray16_lossy -i source_gray16.pgm -r 30 -n 4
c no_mct -i source.ppm -mct 0 -r 10
c one_resolution -i source.ppm -n 1
c eight_levels -i source.ppm -n 6 -r 25
c odd_size -i source_odd.ppm -n 3
c odd_size_lossy -i source_odd.ppm -n 4 -r 5
c odd_offset -i source_odd.ppm -d 3,5 -n 3 -r 8
c tiny -i source_tiny.ppm -n 1
c subsampled -i source.ppm -s 2,2
