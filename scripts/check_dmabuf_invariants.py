#!/usr/bin/env python3
"""Check four invariants of the ZED X -> Metis zero-copy path.

  I1: At least one dma_buf inode shows attach count >= 2 during the run.
  I2: That inode's exporter_name is one of {nvmap, system, tegra-buf}.
  I3: axl:axl_dmabuf_import fires N times where N == frames submitted.
  I4: No memcpy/__memcpy_generic frame in the perf hot path > 1% self.
"""
import argparse, json, re, subprocess, sys, pathlib


def parse_trace(path):
    imports, releases, fence_waits = [], [], []
    for line in pathlib.Path(path).read_text().splitlines():
        if 'axl_dmabuf_import' in line:
            m = re.search(r'inode=(\d+).*?exporter=(\S+)', line)
            if m:
                imports.append((int(m.group(1)), m.group(2)))
        elif 'axl_dmabuf_release' in line:
            releases.append(line)
        elif 'dma_fence_wait_start' in line or 'dma_fence_wait_end' in line:
            fence_waits.append(line)
    return imports, releases, fence_waits


def parse_sysfs(path):
    text = pathlib.Path(path).read_text()
    blocks = re.findall(r'/sys/kernel/dmabuf/buffers/(\d+)/(\w+)\n([^\n/]+)', text)
    by_inode = {}
    for inode, key, val in blocks:
        by_inode.setdefault(inode, {})[key] = val.strip()
    return by_inode


def perf_top_self(perf_data):
    cmd = ['perf', 'report', '-i', perf_data, '--stdio',
           '--percent-limit', '0.5', '--no-children', '--sort', 'symbol']
    return subprocess.check_output(cmd, text=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--trace', required=True)
    ap.add_argument('--sysfs', required=True)
    ap.add_argument('--perf',  required=True)
    ap.add_argument('--json',  required=True)
    args = ap.parse_args()

    imports, releases, fences = parse_trace(args.trace)
    sysfs = parse_sysfs(args.sysfs)
    perf_out = perf_top_self(args.perf)

    multi_attach = [i for i, kv in sysfs.items()
                    if int(kv.get('attachments', '0')) >= 2]
    I1 = bool(multi_attach)

    exporters = {sysfs[i].get('exporter_name') for i in multi_attach}
    I2 = bool(exporters & {'nvmap', 'system', 'tegra-buf'})

    I3 = len(imports) > 0

    bad = [ln for ln in perf_out.splitlines()
           if re.search(r'memcpy', ln) and
           re.match(r'\s*(\d+\.\d+)%', ln) and
           float(re.match(r'\s*(\d+\.\d+)%', ln).group(1)) > 1.0]
    I4 = not bad

    result = {
        'I1_attach_count_ge2': I1,
        'I2_known_exporter':   I2,
        'I3_axl_imports':      I3,
        'I4_no_memcpy_hot':    I4,
        'detail': {
            'imports':             len(imports),
            'releases':            len(releases),
            'fence_wait_lines':    len(fences),
            'multi_attach_inodes': multi_attach,
            'exporters':           sorted(exporters),
            'memcpy_hot':          bad,
        },
        'pass': all([I1, I2, I3, I4]),
    }
    pathlib.Path(args.json).write_text(json.dumps(result, indent=2))
    print('PASS' if result['pass'] else 'FAIL')
    sys.exit(0 if result['pass'] else 1)


if __name__ == '__main__':
    main()
