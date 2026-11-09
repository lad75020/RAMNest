#pragma once
#include <charconv>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace native_tmpfs {
inline constexpr const char* protocol = "native-tmpfs-v1";
inline uint64_t number(const std::string& s) {
    uint64_t n = 0;
    auto [end, ec] = std::from_chars(s.data(), s.data() + s.size(), n);
    if (s.empty() || ec != std::errc() || end != s.data() + s.size() || (s.size() > 1 && s[0] == '0'))
        throw std::runtime_error("Invalid unsigned decimal argument");
    return n;
}
inline bool uuid(const std::string& s) {
    if (s.size() != 36) return false;
    for (size_t i = 0; i < s.size(); ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'A' && s[i] <= 'F'))) return false;
    }
    return true;
}
struct Request {
    std::string operation, session;
    uint32_t uid = 0;
    uint64_t rootDevice = 0, rootInode = 0, mountDevice = 0, mountInode = 0, capacity = 0;
    uint32_t fsid0 = 0, fsid1 = 0;
    bool nobrowse = true;
    std::string root() const { return "/Users/Shared/RAMNestNative-" + std::to_string(uid); }
    std::string slot() const { return root() + "/" + session; }
    std::string mount() const { return slot() + "/mount"; }
    static Request parse(const std::vector<std::string>& a) {
        if (a.size() < 3) throw std::runtime_error("Missing bounded native operation");
        Request r; r.operation = a[0]; auto uid = number(a[1]); r.session = a[2];
        if (uid < 501 || uid > UINT32_MAX || !uuid(r.session)) throw std::runtime_error("Invalid native slot owner/session");
        r.uid = static_cast<uint32_t>(uid);
        const bool mount = r.operation == "mount";
        const bool control = r.operation == "readonly" || r.operation == "freeze" || r.operation == "thaw" || r.operation == "unmount";
        const bool reserved = r.operation == "release";
        if (r.operation == "reserve") { if (a.size() != 3) throw std::runtime_error("Unexpected reserve arguments"); return r; }
        if ((!mount && !control && !reserved) || a.size() != (mount ? 9u : control ? 10u : 7u))
            throw std::runtime_error("Unknown operation or argument count");
        r.rootDevice = number(a[3]); r.rootInode = number(a[4]); r.mountDevice = number(a[5]); r.mountInode = number(a[6]);
        if (!r.rootInode || !r.mountInode) throw std::runtime_error("Missing slot identity");
        if (mount) {
            r.capacity = number(a[7]);
            if (a[8] != "true" && a[8] != "false") throw std::runtime_error("Invalid visibility");
            r.nobrowse = a[8] == "true";
        }
        if (control) {
            auto x = number(a[7]), y = number(a[8]);
            if (x > UINT32_MAX || y > UINT32_MAX || (x == 0 && y == 0)) throw std::runtime_error("Invalid filesystem identity");
            r.fsid0 = static_cast<uint32_t>(x); r.fsid1 = static_cast<uint32_t>(y); r.capacity = number(a[9]);
        }
        if ((mount || control) && (r.capacity < (16ull << 20) || r.capacity > (1ull << 50)))
            throw std::runtime_error("Invalid native capacity");
        return r;
    }
};
}

namespace native_tmpfs {
inline constexpr const char* quiescenceReceipt = "no-regular-vnode-references-v1";
// Parse the complete, privileged, filesystem-selected lsof transcript. A closed
// descriptor MAP_SHARED mapping appears as ftxt/tREG on the measured host.
// Reject ALL logical regular vnode references, not just writable fd labels.
inline void validateReferences(const std::string& output, const std::string& errors,
                               int exitStatus, const std::string& mount, uint64_t observerPID) {
    if (exitStatus != 0 || !errors.empty() || output.empty() || output.back() != '\n')
        throw std::runtime_error("Mapping scan failed, warned or returned an incomplete transcript; no coherent snapshot allowed");
    uint64_t pid = 0; std::string fd, type, name; bool sawObserver = false, sawCommand = false, processReference = false;
    auto finish = [&] {
        if (fd.empty()) return;
        if (!pid || !sawCommand || type.empty() || name.empty())
            throw std::runtime_error("Incomplete vnode reference from mapping scan");
        processReference = true;
        if ((name != mount && name.rfind(mount + "/", 0) != 0) || name.find("/../") != std::string::npos ||
            name.find("/./") != std::string::npos || name.ends_with("/..") || name.ends_with("/."))
            throw std::runtime_error("Unresolved or unexpected vnode path in mapping scan");
        if (type == "DIR") {
            if (pid == observerPID && name == mount) sawObserver = true;
        } else if (type == "REG") {
            // OS-owned root metadata is outside the logical user tree. The
            // protected root prevents a user hardlink/rename into this subtree.
            if (name.rfind(mount + "/.fseventsd/", 0) != 0)
                throw std::runtime_error("Native snapshot refused: regular files or shared mappings remain open. Close all writers and mapped readers; Ignore Busy cannot override this guard");
        } else throw std::runtime_error("Unknown vnode type in mapping scan; no coherent snapshot allowed");
        fd.clear(); type.clear(); name.clear();
    };
    size_t offset = 0;
    while (offset < output.size()) {
        size_t end = output.find('\n', offset);
        if (end == std::string::npos || end == offset) throw std::runtime_error("Malformed mapping scan frame");
        std::string line = output.substr(offset, end - offset); offset = end + 1;
        if (line.find('\0') != std::string::npos) throw std::runtime_error("NUL in mapping scan");
        std::string value = line.substr(1);
        switch (line[0]) {
            case 'p': finish(); if (pid && !processReference) throw std::runtime_error("Process without vnode data in mapping scan"); processReference = false; pid = number(value); if (!pid || pid > INT32_MAX) throw std::runtime_error("Invalid scan process"); sawCommand = false; break;
            case 'c': if (!pid || sawCommand || value.empty() || !fd.empty()) throw std::runtime_error("Invalid scan process header"); sawCommand = true; break;
            case 'f': finish(); if (!pid || value.empty()) throw std::runtime_error("Invalid scan descriptor"); fd = value; break;
            case 't': if (fd.empty() || !type.empty() || value.empty()) throw std::runtime_error("Invalid scan type"); type = value; break;
            case 'n': if (fd.empty() || !name.empty() || value.empty()) throw std::runtime_error("Invalid scan name"); name = value; break;
            default: throw std::runtime_error("Unknown field in mapping scan; no coherent snapshot allowed");
        }
    }
    finish();
    if (!processReference) throw std::runtime_error("Truncated process record in mapping scan");
    if (!sawObserver) throw std::runtime_error("Mapping scan did not observe its own bound mount descriptor; incomplete scan");
}
}

namespace native_tmpfs {
// Root-only control.lock payload binds caller journal values to the reservation
// before a mounted path hides its underlying inode. It is never supplied via IPC.
struct SlotAuthority {
    Request binding;
    std::string encoded() const {
        const auto& r = binding;
        return std::string(protocol) + "\t" + std::to_string(r.uid) + "\t" + r.session + "\t" +
            std::to_string(r.rootDevice) + "\t" + std::to_string(r.rootInode) + "\t" +
            std::to_string(r.mountDevice) + "\t" + std::to_string(r.mountInode) + "\t" +
            std::to_string(r.capacity) + "\t" + std::to_string(r.fsid0) + "\t" + std::to_string(r.fsid1) + "\n";
    }
    static SlotAuthority parse(const std::string& bytes) {
        if (bytes.empty() || bytes.size() > 512 || bytes.back() != '\n' || bytes.find('\n') != bytes.size() - 1)
            throw std::runtime_error("Invalid protected slot receipt");
        std::vector<std::string> fields; size_t start = 0;
        while (true) { auto end = bytes.find('\t', start); if (end == std::string::npos) { fields.push_back(bytes.substr(start, bytes.size() - start - 1)); break; } fields.push_back(bytes.substr(start, end - start)); start = end + 1; }
        if (fields.size() != 10 || fields[0] != protocol) throw std::runtime_error("Unknown protected slot receipt");
        auto r = Request::parse({"release", fields[1], fields[2], fields[3], fields[4], fields[5], fields[6]});
        r.capacity = number(fields[7]); auto x = number(fields[8]), y = number(fields[9]);
        if (x > UINT32_MAX || y > UINT32_MAX || (r.capacity == 0) != (x == 0 && y == 0) ||
            (r.capacity != 0 && (r.capacity < (16ull << 20) || r.capacity > (1ull << 50))))
            throw std::runtime_error("Invalid protected native identity/capacity");
        r.fsid0 = static_cast<uint32_t>(x); r.fsid1 = static_cast<uint32_t>(y); return {r};
    }
    void validate(const Request& r) const {
        const auto& b = binding;
        if (r.uid != b.uid || r.session != b.session || r.rootDevice != b.rootDevice || r.rootInode != b.rootInode ||
            r.mountDevice != b.mountDevice || r.mountInode != b.mountInode)
            throw std::runtime_error("Protected native reservation identity mismatch; no operation performed");
        if (r.operation == "mount") {
            if (b.capacity || b.fsid0 || b.fsid1) throw std::runtime_error("Native slot already used; no mount adoption");
        } else if (r.operation != "release" && (r.capacity != b.capacity || r.fsid0 != b.fsid0 || r.fsid1 != b.fsid1 || !b.capacity))
            throw std::runtime_error("Protected native fsid/capacity receipt mismatch; no operation performed");
    }
};
}

namespace native_tmpfs {
inline bool capacityMatches(uint64_t actual, uint64_t requested, uint64_t page) {
    if (!page || requested > UINT64_MAX - (page - 1)) return false;
    return actual >= (requested / page) * page && actual <= ((requested + page - 1) / page) * page;
}

struct PeriodicSchedule {
    uint64_t minutes = 0;
    std::string authorization, verification;
    static PeriodicSchedule parse(const std::string& frame) {
        std::vector<std::string> fields; size_t start = 0;
        while (true) { auto end = frame.find('\t', start); fields.push_back(frame.substr(start, end == std::string::npos ? end : end - start)); if (end == std::string::npos) break; start = end + 1; }
        if (fields.size() != 4 || fields[0] != "period") throw std::runtime_error("Invalid periodic frame");
        PeriodicSchedule p; p.minutes = number(fields[1]); p.authorization = fields[2]; p.verification = fields[3];
        if (!(p.minutes == 0 || p.minutes == 5 || p.minutes == 15 || p.minutes == 30 || p.minutes == 60 || p.minutes == 360 || p.minutes == 720 || p.minutes == 1440) ||
            (p.minutes == 0 ? p.authorization != "-" : !uuid(p.authorization)) ||
            (p.verification != "sha256" && p.verification != "sizeAndModTime")) throw std::runtime_error("Invalid periodic authority");
        return p;
    }
};
}
