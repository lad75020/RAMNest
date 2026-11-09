#include "NativeTmpfsProtocol.hpp"
#include <cassert>
#include <functional>
using namespace native_tmpfs;
static void rejects(const std::function<void()>& body) { bool failed = false; try { body(); } catch (...) { failed = true; } assert(failed); }
int main() {
    const std::string session = "CABB73E4-9FD3-48DF-8057-7B07CF95FB90";
    auto reserve = Request::parse({"reserve", "501", session});
    assert(reserve.mount() == "/Users/Shared/RAMNestNative-501/" + session + "/mount");
    auto m = Request::parse({"mount", "501", session, "10", "11", "10", "12", "67108864", "false"});
    assert(m.capacity == 67108864 && !m.nobrowse);
    for (auto& op : {"readonly", "freeze", "thaw", "unmount"}) {
        auto r = Request::parse({op, "501", session, "10", "11", "10", "12", "4294967295", "2", "67108864"});
        assert(r.fsid0 == UINT32_MAX && r.mountInode == 12);
    }
    auto release = Request::parse({"release", "501", session, "10", "11", "10", "12"}); assert(release.capacity == 0);
    for (auto uid : {"0", "500", "0501", "501;id", "-1", "4294967296", "501\n"})
        rejects([&] { Request::parse({"reserve", uid, session}); });
    for (auto token : {"../../tmp", "/Users/user/data", "$(id)", "cabb73e4-9fd3-48df-8057-7b07cf95fb90", ""})
        rejects([&] { Request::parse({"reserve", "501", token}); });
    for (auto op : {"resize", "chown", "exec", "export", "install", "mount;id"})
        rejects([&] { Request::parse({op, "501", session}); });
    rejects([&] { Request::parse({"reserve", "501", session, "/arbitrary/path"}); });
    rejects([&] { Request::parse({"mount", "501", session, "10", "0", "10", "12", "67108864", "true"}); });
    rejects([&] { Request::parse({"mount", "501", session, "10", "11", "10", "12", "1", "true"}); });
    rejects([&] { Request::parse({"mount", "501", session, "10", "11", "10", "12", "67108864", "true -o suid"}); });
    rejects([&] { Request::parse({"freeze", "501", session, "10", "11", "10", "12", "4294967296", "2", "67108864"}); });
    rejects([&] { Request::parse({"freeze", "501", session, "10", "11", "10", "12", "0", "0", "67108864"}); });
    const std::string path = reserve.mount();
    const std::string observer = "p433\ncmds\nf50\ntDIR\nn" + path + "\n";
    validateReferences(observer, "", 0, path, 433);
    validateReferences(observer + "p99\ncfseventsd\nf6u\ntREG\nn" + path + "/.fseventsd/log\n", "", 0, path, 433);
    // Measured fd-closed MAP_SHARED transcript, with no numeric file fd.
    auto mapped = observer + "p30598\ncpython3.13\nftxt\ntREG\nn" + path + "/tree/data/mapped\n";
    rejects([&] { validateReferences(mapped, "", 0, path, 433); });
    for (auto label : {"4r", "4u", "4w", "txt", "mem"}) {
        auto open = observer + "p52\ncwriter\nf" + label + "\ntREG\nn" + path + "/tree/data/file\n";
        rejects([&] { validateReferences(open, "", 0, path, 433); });
    }
    rejects([&] { validateReferences(observer, "warning: incomplete scan", 0, path, 433); });
    rejects([&] { validateReferences(observer, "", 1, path, 433); });
    rejects([&] { validateReferences(observer, "", 0, path, 434); });
    for (auto broken : {"", "p433\ncmds\nf50\ntDIR\n", "p433\ncmds\nf50\nnunknown\n", "p433\n", "p433\ncmds\nf50\ntUNKNOWN\nnpath\n"})
        rejects([&] { validateReferences(broken, "", 0, path, 433); });
    for (auto tail : {"p1\n", "?unknown\n", "\n", "p1\ncwriter\nftxt\ntREG", "p1\ncwriter\nftxt\ntREG\nn"})
        rejects([&] { validateReferences(observer + tail, "", 0, path, 433); });
    rejects([&] { validateReferences(observer + "p9\ncbad\nf4\ntREG\nn" + path + "/.fseventsd/../tree/data/file\n", "", 0, path, 433); });
    for (auto suffix : {"-foreign", "/tree/..", "/tree/."})
        rejects([&] { validateReferences(observer + "p9\ncbad\nf4\ntDIR\nn" + path + suffix + "\n", "", 0, path, 433); });
    auto reservedRequest = Request::parse({"release", "501", session, "10", "11", "10", "12"});
    auto reservedAuthority = SlotAuthority::parse(SlotAuthority{reservedRequest}.encoded());
    reservedAuthority.validate(m);
    auto mountedRequest = Request::parse({"freeze", "501", session, "10", "11", "10", "12", "42", "2", "67108864"});
    auto mountedAuthority = SlotAuthority::parse(SlotAuthority{mountedRequest}.encoded());
    mountedAuthority.validate(mountedRequest);
    rejects([&] { mountedAuthority.validate(m); });
    auto wrong = mountedRequest; wrong.mountInode += 1;
    rejects([&] { mountedAuthority.validate(wrong); }); // before destructive unmount
    wrong = mountedRequest; wrong.fsid0 += 1;
    rejects([&] { mountedAuthority.validate(wrong); });
    wrong = mountedRequest; wrong.capacity += 4096;
    rejects([&] { mountedAuthority.validate(wrong); });
    rejects([&] { SlotAuthority::parse("unknown\t501\n"); });
    rejects([&] { SlotAuthority::parse(SlotAuthority{mountedRequest}.encoded() + "extra\n"); });
    assert(capacityMatches(67108864, 67108864, 16384));
    assert(capacityMatches(67125248, 67108865, 16384));
    assert(!capacityMatches(134217728, 67108864, 16384));
    assert(!capacityMatches(0, 67108864, 16384));
    assert(!capacityMatches(UINT64_MAX, UINT64_MAX, 16384));
    auto period = PeriodicSchedule::parse("period\t15\t" + session + "\tsha256");
    assert(period.minutes == 15 && period.authorization == session && period.verification == "sha256");
    assert(PeriodicSchedule::parse("period\t0\t-\tsizeAndModTime").minutes == 0);
    for (auto bad : {"period\t15", "period\t15\t-\tsha256", "period\t0\tunknown\tsha256", "period\t5;id\t-\tsha256", "period\t0\t-\tunknown"})
        rejects([&] { PeriodicSchedule::parse(bad); });
}
