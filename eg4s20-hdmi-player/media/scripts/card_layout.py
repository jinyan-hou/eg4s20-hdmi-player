"""Read-only FAT/exFAT file allocation and physical LBA check (Windows, stdlib).

Usage: python card_layout.py F:\\ANLU_TEST.BMP
       python card_layout.py --self-test
Exit 0: complete, contiguous mapping; 1: incomplete/error; 2: fragmented.
Nothing is written to the card. No privilege adjustment or elevation is attempted.
Recheck after replacing/copying the file: its allocation can change.

API definitions: Microsoft winioctl.h and Microsoft Learn pages for
FSCTL_GET_RETRIEVAL_POINTERS, FSCTL_GET_RETRIEVAL_POINTER_BASE,
IOCTL_DISK_GET_PARTITION_INFO_EX, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS.
The retrieval base is measured in sectors; LCN is measured in clusters.
"""

import argparse
import ctypes as C
from ctypes import wintypes as W
import json
import os
from pathlib import Path
import struct


FSCTL_GET_RETRIEVAL_POINTERS = 0x90073
FSCTL_GET_RETRIEVAL_POINTER_BASE = 0x90234
IOCTL_DISK_GET_PARTITION_INFO_EX = 0x70048
IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS = 0x560000
ERROR_MORE_DATA = 234
ERROR_HANDLE_EOF = 38


def parse_extents(data):
    """Decode native RETRIEVAL_POINTERS_BUFFER (8-byte LARGE_INTEGER alignment)."""
    if len(data) < 16:
        raise ValueError("Short RETRIEVAL_POINTERS_BUFFER header")
    count = struct.unpack_from("<I", data)[0]
    vcn = struct.unpack_from("<q", data, 8)[0]
    if vcn < 0 or len(data) < 16 + count * 16:
        raise ValueError("Invalid/truncated RETRIEVAL_POINTERS_BUFFER")
    extents = []
    for index in range(count):
        next_vcn, lcn = struct.unpack_from("<qq", data, 16 + index * 16)
        if next_vcn <= vcn or lcn < -1:
            raise ValueError("Invalid extent bounds")
        extents.append({"vcn": vcn, "lcn": lcn, "clusters": next_vcn - vcn})
        vcn = next_vcn
    return extents


def is_contiguous(extents, required_clusters):
    """Adjacent physical runs count as contiguous even if returned separately."""
    if not required_clusters:
        return None
    next_vcn = 0
    next_lcn = None
    for extent in extents:
        if extent["vcn"] != next_vcn or extent["lcn"] < 0:
            return False
        if next_lcn is not None and extent["lcn"] != next_lcn:
            return False
        next_vcn += extent["clusters"]
        next_lcn = extent["lcn"] + extent["clusters"]
        if next_vcn >= required_clusters:
            return True
    raise ValueError("Extents do not cover the file length")


class Win32:
    def __init__(self):
        self.dll = C.WinDLL("kernel32", use_last_error=True)
        signatures = {
            "CreateFileW": (W.HANDLE, [W.LPCWSTR, W.DWORD, W.DWORD, W.LPVOID,
                                      W.DWORD, W.DWORD, W.HANDLE]),
            "CloseHandle": (W.BOOL, [W.HANDLE]),
            "DeviceIoControl": (W.BOOL, [W.HANDLE, W.DWORD, W.LPVOID, W.DWORD,
                                         W.LPVOID, W.DWORD, C.POINTER(W.DWORD), W.LPVOID]),
            "GetDiskFreeSpaceW": (W.BOOL, [W.LPCWSTR] + [C.POINTER(W.DWORD)] * 4),
            "GetVolumeInformationW": (W.BOOL, [W.LPCWSTR, W.LPWSTR, W.DWORD,
                                               C.POINTER(W.DWORD), C.POINTER(W.DWORD),
                                               C.POINTER(W.DWORD), W.LPWSTR, W.DWORD]),
            "GetFileSizeEx": (W.BOOL, [W.HANDLE, C.POINTER(C.c_longlong)]),
        }
        for name, (result, arguments) in signatures.items():
            function = getattr(self.dll, name)
            function.restype, function.argtypes = result, arguments

    def open(self, path, volume=False):
        # Retrieval-pointer-base requires a readable volume handle on this FastFAT
        # device; a zero-access handle gives ERROR_INVALID_FUNCTION. Both handles
        # are read-only. Deny file writers/deletion during the allocation check.
        handle = self.dll.CreateFileW(path, 0x80000000,
                                      3 if volume else 1, None, 3, 0, None)
        if handle == C.c_void_p(-1).value:
            raise C.WinError(C.get_last_error())
        return handle

    def ioctl(self, handle, code, output_size, input_data=None, partial=False):
        output = C.create_string_buffer(output_size)
        input_buffer = C.create_string_buffer(input_data) if input_data is not None else None
        returned = W.DWORD()
        success = self.dll.DeviceIoControl(
            handle, code, input_buffer, len(input_data) if input_data is not None else 0,
            output, output_size, C.byref(returned), None)
        error = 0 if success else C.get_last_error()
        if error and not (partial and error in (ERROR_MORE_DATA, ERROR_HANDLE_EOF)):
            raise C.WinError(error)
        return output.raw[:returned.value], error

    def file_extents(self, handle):
        extents, requested_vcn = [], 0
        while True:
            data, error = self.ioctl(handle, FSCTL_GET_RETRIEVAL_POINTERS, 65536,
                                     struct.pack("<q", requested_vcn), partial=True)
            if error == ERROR_HANDLE_EOF:
                break
            batch = parse_extents(data)
            # Windows may round StartingVcn down. Trim an already-received prefix.
            for extent in batch:
                end = extent["vcn"] + extent["clusters"]
                if end <= requested_vcn:
                    continue
                skipped = max(0, requested_vcn - extent["vcn"])
                extents.append({"vcn": extent["vcn"] + skipped,
                                "lcn": extent["lcn"] + skipped if extent["lcn"] >= 0 else -1,
                                "clusters": extent["clusters"] - skipped})
            if not error:
                break
            next_vcn = batch[-1]["vcn"] + batch[-1]["clusters"] if batch else requested_vcn
            if next_vcn <= requested_vcn:
                raise ValueError("Extent pagination made no progress")
            requested_vcn = next_vcn
        return extents


def check_layout(filename):
    if os.name != "nt":
        raise ValueError("Windows is required for card queries")
    path = Path(filename).resolve(strict=True)
    if not path.is_file() or len(path.drive) != 2 or path.drive[1] != ":":
        raise ValueError("Choose a regular file on a local drive letter")
    api = Win32()
    root = path.drive + "\\"
    report = {"path": str(path), "errors": [], "contiguous": None,
              "first_file_lba": None, "first_file_lba_512": None,
              "lba_verified": False, "permission_may_be_required": False}

    def query(stage, operation):
        try:
            return operation()
        except (OSError, ValueError, struct.error) as error:
            code = getattr(error, "winerror", None)
            report["errors"].append({"stage": stage, "winerror": code, "message": str(error)})
            # FastFAT may return ERROR_INVALID_PARAMETER for missing manage-volume
            # access, so 87 on this one query is not proof of a bad LCN formula.
            if code in (5, 1314) or (stage == "retrieval_pointer_base" and code == 87):
                report["permission_may_be_required"] = True
            return None

    sectors_per_cluster, bytes_per_sector, free_clusters, total_clusters = [W.DWORD() for _ in range(4)]
    if not api.dll.GetDiskFreeSpaceW(root, C.byref(sectors_per_cluster), C.byref(bytes_per_sector),
                                    C.byref(free_clusters), C.byref(total_clusters)):
        raise C.WinError(C.get_last_error())
    bps, spc = bytes_per_sector.value, sectors_per_cluster.value
    if not bps or not spc:
        raise ValueError("Invalid sector/cluster geometry")
    report.update(bytes_per_sector=bps, sectors_per_cluster=spc, bytes_per_cluster=bps * spc)
    fs_name = C.create_unicode_buffer(32)
    if not api.dll.GetVolumeInformationW(root, None, 0, None, None, None, fs_name, len(fs_name)):
        raise C.WinError(C.get_last_error())
    report["filesystem"] = fs_name.value
    if fs_name.value.upper() not in ("FAT", "FAT32", "EXFAT"):
        raise ValueError("This LCN-base check is limited to FAT/FAT32/exFAT")

    handle = api.open(str(path))
    try:
        size = C.c_longlong()
        if not api.dll.GetFileSizeEx(handle, C.byref(size)):
            raise C.WinError(C.get_last_error())
        report["file_bytes"] = size.value
        required_clusters = (size.value + bps * spc - 1) // (bps * spc)
        report["required_clusters"] = required_clusters
        extents = query("file_extents", lambda: api.file_extents(handle))
        if extents is not None:
            report["extents"] = extents
            report["extent_count"] = len(extents)
            report["contiguous"] = query("continuity", lambda: is_contiguous(extents, required_clusters))

        volume = query("open_volume", lambda: api.open("\\\\.\\" + path.drive, volume=True))
        if volume is not None:
            try:
                base_data = query("retrieval_pointer_base", lambda: api.ioctl(
                    volume, FSCTL_GET_RETRIEVAL_POINTER_BASE, 8)[0])
                if base_data is not None:
                    if len(base_data) != 8:
                        raise ValueError("Invalid retrieval-pointer base response")
                    report["retrieval_pointer_base_sectors"] = struct.unpack("<q", base_data)[0]
                partition = query("partition_info", lambda: api.ioctl(
                    volume, IOCTL_DISK_GET_PARTITION_INFO_EX, 256)[0])
                if partition is not None:
                    if len(partition) < 28:
                        raise ValueError("Short partition-info response")
                    style, offset, length, number = struct.unpack_from("<I4xqqI", partition)
                    report.update(partition_style={0: "MBR", 1: "GPT", 2: "RAW"}.get(style, "UNKNOWN"),
                                  partition_offset_bytes=offset, partition_length_bytes=length,
                                  partition_number=number)
                disk_data = query("volume_disk_extents", lambda: api.ioctl(
                    volume, IOCTL_VOLUME_GET_VOLUME_DISK_EXTENTS, 4096)[0])
                if disk_data is not None:
                    if len(disk_data) < 8:
                        raise ValueError("Short volume-disk-extents response")
                    count = struct.unpack_from("<I", disk_data)[0]
                    if len(disk_data) < 8 + count * 24:
                        raise ValueError("Truncated volume-disk-extents response")
                    report["volume_disk_extents"] = [dict(zip(("disk_number", "offset_bytes", "length_bytes"),
                        struct.unpack_from("<I4xqq", disk_data, 8 + index * 24))) for index in range(count)]
            finally:
                api.dll.CloseHandle(volume)

        def calculate_lba():
            base = report.get("retrieval_pointer_base_sectors")
            offset = report.get("partition_offset_bytes")
            disks = report.get("volume_disk_extents")
            if base is None or offset is None or disks is None or not extents or not required_clusters:
                return
            if len(disks) != 1 or disks[0]["offset_bytes"] != offset:
                raise ValueError("Volume is not a single disk extent matching the partition offset")
            if base < 0 or offset < 0 or offset % bps or extents[0]["vcn"] != 0 or extents[0]["lcn"] < 0:
                raise ValueError("Invalid/alignment-unsafe LBA inputs")
            for extent in extents:
                if extent["lcn"] < 0:
                    raise ValueError("Sparse extents cannot be read as a raw card file")
                volume_sector = base + extent["lcn"] * spc
                if (volume_sector + extent["clusters"] * spc) * bps > report["partition_length_bytes"]:
                    raise ValueError("File extent exceeds partition bounds")
                extent["first_volume_sector"] = volume_sector
                extent["first_disk_lba"] = offset // bps + volume_sector
            first_byte = extents[0]["first_disk_lba"] * bps
            report.update(first_file_lba=extents[0]["first_disk_lba"], first_file_offset_bytes=first_byte,
                          first_file_lba_512=first_byte // 512 if first_byte % 512 == 0 else None,
                          lba_verified=True)

        query("lba_calculation", calculate_lba)
    finally:
        api.dll.CloseHandle(handle)
    return report


def self_test():
    adjacent = parse_extents(struct.pack("<I4xq", 2, 0) + struct.pack("<qqqq", 3, 4, 7, 7))
    assert adjacent == [{"vcn": 0, "lcn": 4, "clusters": 3}, {"vcn": 3, "lcn": 7, "clusters": 4}]
    assert is_contiguous(adjacent, 7) is True
    assert is_contiguous([adjacent[0], {"vcn": 3, "lcn": 8, "clusters": 4}], 7) is False
    assert is_contiguous([{"vcn": 0, "lcn": -1, "clusters": 7}], 7) is False
    for data in (b"", struct.pack("<I4xq", 1, 0)):
        try:
            parse_extents(data)
        except ValueError:
            pass
        else:
            raise AssertionError("Truncated response was accepted")
    print("self-test passed: aligned decoding, adjacent/fragmented/sparse runs, truncated buffers")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("file", nargs="?")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    if not args.file:
        parser.error("a file path or --self-test is required")
    try:
        report = check_layout(args.file)
    except (OSError, ValueError, struct.error) as error:
        report = {"path": args.file, "errors": [{"stage": "check_layout",
                   "winerror": getattr(error, "winerror", None), "message": str(error)}],
                  "lba_verified": False}
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if report.get("errors") or not report.get("lba_verified"):
        return 1
    return 0 if report.get("contiguous") else 2


if __name__ == "__main__":
    raise SystemExit(main())
