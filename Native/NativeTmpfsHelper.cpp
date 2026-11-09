// Production helper: bounded one-shot administrator controls, or a separate
// unprivileged mount pin. No FUSE, page engine, credential or root IPC path.
#include "NativeTmpfsProtocol.hpp"
#include <sys/acl.h>
#include <sys/file.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <dirent.h>
#include <fcntl.h>
#include <pwd.h>
#include <poll.h>
#include <signal.h>
#include <algorithm>
#include <spawn.h>
#include <unistd.h>
#include <cerrno>
#include <chrono>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>

using namespace native_tmpfs;
namespace {
struct FD {
    int value;
    explicit FD(int fd) : value(fd) { if (fd < 0) throw std::runtime_error("Cannot open bound directory: " + std::string(strerror(errno))); }
    ~FD() { if (value >= 0) close(value); }
    FD(const FD&) = delete; FD& operator=(const FD&) = delete;
};
void require(bool condition, const char* reason) { if (!condition) throw std::runtime_error(reason); }
uint64_t device(dev_t d) { return static_cast<uint64_t>(static_cast<int64_t>(d)); }
struct stat info(int fd) { struct stat s{}; require(fstat(fd, &s) == 0, "Cannot stat bound object"); return s; }
void noACL(int fd) {
    errno = 0; acl_t acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED);
    if (!acl) { require(errno == ENOENT || errno == ENOTSUP, "Cannot inspect private slot ACL"); return; }
    acl_entry_t e{}; errno = 0; int n = acl_get_entry(acl, ACL_FIRST_ENTRY, &e); int err = errno; acl_free(acl);
    require(n == -1 && err == EINVAL, "ACL-bearing private runtime slot is unsupported");
}
void owned(int fd, mode_t mode) {
    auto s = info(fd);
    require(S_ISDIR(s.st_mode) && s.st_uid == 0 && (s.st_mode & 07777) == mode, "Runtime slot must be a root-owned directory with exact protected mode");
    require(s.st_flags == 0, "Unexpected runtime slot flags"); noACL(fd);
}
int child(int fd, const std::string& name) { return openat(fd, name.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); }
void identity(int fd, uint64_t dev, uint64_t ino) {
    auto s = info(fd); require(device(s.st_dev) == dev && s.st_ino == ino, "Runtime slot identity changed; retained");
}
struct statfs filesystem(int fd) { struct statfs fs{}; require(fstatfs(fd, &fs) == 0, "Cannot read bound mount identity"); return fs; }
bool atMount(const struct statfs& fs, const std::string& path) { return std::string(fs.f_mntonname) == path; }
void internal(int fd, int shared) {
    auto a = filesystem(fd), b = filesystem(shared);
    require((a.f_flags & MNT_LOCAL) && !(a.f_flags & MNT_RDONLY) && a.f_fsid.val[0] == b.f_fsid.val[0] && a.f_fsid.val[1] == b.f_fsid.val[1], "Native slot requires writable internal storage");
}
void native(const struct statfs& fs, const Request& r, int readonly = -1) {
    require(std::string(fs.f_fstypename) == "tmpfs" && atMount(fs, r.mount()) &&
        static_cast<uint32_t>(fs.f_fsid.val[0]) == r.fsid0 && static_cast<uint32_t>(fs.f_fsid.val[1]) == r.fsid1,
        "Native mount type/path/fsid mismatch; no operation performed");
    require((fs.f_flags & (MNT_NOSUID | MNT_NODEV)) == (MNT_NOSUID | MNT_NODEV), "Native safety mount flags changed");
    if (r.capacity) {
        const auto page = sysconf(_SC_PAGESIZE);
        require(page > 0 && fs.f_bsize > 0 && uint64_t(fs.f_blocks) <= UINT64_MAX / uint64_t(fs.f_bsize), "Invalid native capacity accounting");
        require(capacityMatches(uint64_t(fs.f_blocks) * uint64_t(fs.f_bsize), r.capacity, uint64_t(page)), "Native maximum differs from requested capacity; no control receipt authorized");
    }
    if (readonly >= 0) require(bool(fs.f_flags & MNT_RDONLY) == bool(readonly), "Native read-only state did not match the required state");
}
// Never inherit a caller's environment into the privileged system utilities.
void run(const char* executable, const std::vector<std::string>& args) {
    std::vector<char*> argv{const_cast<char*>(executable)};
    for (auto& a : args) argv.push_back(const_cast<char*>(a.c_str())); argv.push_back(nullptr);
    char path[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin"; char lang[] = "LC_ALL=C"; char* env[] = {path, lang, nullptr};
    posix_spawnattr_t attr; require(posix_spawnattr_init(&attr) == 0, "spawn init");
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    pid_t pid = 0; int error = posix_spawn(&pid, executable, nullptr, &attr, argv.data(), env); posix_spawnattr_destroy(&attr);
    require(error == 0, "Cannot launch native system utility");
    int status = 0; pid_t waited; do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    require(waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0, "Native macOS mount control failed; retained. Check administrator authorization and mount capability");
}
void scanMappings(const Request& r) {
    int outPipe[2], errPipe[2];
    require(pipe(outPipe) == 0, "Cannot capture mapping scan");
    FD outRead(outPipe[0]), outWrite(outPipe[1]);
    require(pipe(errPipe) == 0, "Cannot capture mapping scan diagnostics");
    FD errRead(errPipe[0]), errWrite(errPipe[1]);
    posix_spawn_file_actions_t actions;
    require(posix_spawn_file_actions_init(&actions) == 0, "Cannot initialize mapping scan");
    posix_spawn_file_actions_adddup2(&actions, outWrite.value, STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, errWrite.value, STDERR_FILENO);
    posix_spawn_file_actions_addclose(&actions, outRead.value);
    posix_spawn_file_actions_addclose(&actions, errRead.value);
    posix_spawnattr_t attributes; require(posix_spawnattr_init(&attributes) == 0, "Cannot initialize scan attributes");
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    std::vector<std::string> values = {"/usr/sbin/lsof", "-nP", "-F", "pcftn", "+f", "--", r.mount()};
    std::vector<char*> argv; for (auto& v : values) argv.push_back(v.data()); argv.push_back(nullptr);
    char path[] = "PATH=/usr/bin:/bin:/usr/sbin:/sbin", lang[] = "LC_ALL=C"; char* environment[] = {path, lang, nullptr};
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, "/usr/sbin/lsof", &actions, &attributes, argv.data(), environment);
    posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes);
    require(spawned == 0, "Cannot launch privileged mapping detector");
    close(outWrite.value); outWrite.value = -1; close(errWrite.value); errWrite.value = -1;
    fcntl(outRead.value, F_SETFL, O_NONBLOCK); fcntl(errRead.value, F_SETFL, O_NONBLOCK);
    std::string output, errors; bool outDone = false, errDone = false; int status = 0; bool waited = false;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
    try {
        while (!outDone || !errDone || !waited) {
            require(std::chrono::steady_clock::now() < deadline, "Mapping scan timed out; no coherent snapshot allowed");
            pollfd descriptors[2] = {{outRead.value, POLLIN, 0}, {errRead.value, POLLIN, 0}};
            int ready = poll(descriptors, 2, 50); if (ready < 0 && errno == EINTR) continue;
            require(ready >= 0, "Mapping scan polling failed");
            for (int i = 0; i < 2; ++i) {
                bool& done = i == 0 ? outDone : errDone; auto& text = i == 0 ? output : errors;
                if (done) continue;
                char buffer[8192];
                while (true) {
                    ssize_t count = read(descriptors[i].fd, buffer, sizeof(buffer));
                    if (count == 0) { done = true; break; }
                    if (count < 0 && errno == EINTR) continue;
                    if (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) break;
                    require(count > 0, "Mapping scan read failed");
                    require(text.size() + size_t(count) <= (16u << 20), "Mapping scan exceeded its bounded transcript limit");
                    text.append(buffer, size_t(count));
                }
            }
            if (!waited) {
                pid_t result = waitpid(pid, &status, WNOHANG);
                if (result < 0 && errno == EINTR) continue;
                require(result >= 0, "Cannot reap mapping detector"); waited = result == pid;
            }
        }
    } catch (...) {
        // Only the helper's own bounded detector child; never a user writer.
        if (!waited) { kill(pid, SIGKILL); while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {} }
        throw;
    }
    require(WIFEXITED(status), "Mapping detector did not exit normally");
    validateReferences(output, errors, WEXITSTATUS(status), r.mount(), uint64_t(getpid()));
}
void empty(int fd) {
    FD copy(dup(fd)); DIR* d = fdopendir(copy.value); require(d != nullptr, "Cannot enumerate slot"); copy.value = -1;
    bool isEmpty = true; errno = 0;
    while (auto* e = readdir(d)) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) { isEmpty = false; break; }
    int err = errno; closedir(d); require(isEmpty && err == 0, "Runtime slot contains unexpected objects; retained");
}
void writeAuthority(int fd, const Request& r) {
    auto text = SlotAuthority{r}.encoded();
    require(pwrite(fd, text.data(), text.size(), 0) == static_cast<ssize_t>(text.size()) &&
        ftruncate(fd, static_cast<off_t>(text.size())) == 0 && fsync(fd) == 0, "Cannot commit protected slot receipt");
}
SlotAuthority readAuthority(int fd) {
    auto s = info(fd); require(s.st_size > 0 && s.st_size <= 512, "Missing or oversized protected slot receipt");
    std::string bytes(static_cast<size_t>(s.st_size), '\0');
    require(pread(fd, bytes.data(), bytes.size(), 0) == s.st_size, "Cannot read protected slot receipt");
    return SlotAuthority::parse(bytes);
}
void privileged(Request r) {
    require(getuid() == 0 && geteuid() == 0, "Native mount control requires one-shot macOS administrator authorization");
    auto* user = getpwuid(r.uid); require(user && user->pw_uid == r.uid, "Native slot uid is not a local account");
    uint64_t memory = 0; size_t n = sizeof(memory);
    require(sysctlbyname("hw.memsize", &memory, &n, nullptr, 0) == 0, "Cannot bound capacity");
    if (r.capacity) require(r.capacity <= memory / 4 * 3, "Native capacity exceeds 75% of physical memory");
    // Walk every fixed ancestor without symlinks. Only /Users/Shared may be
    // sticky world-writable; never repair/chown a pre-existing directory.
    FD slash(open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    FD users(child(slash.value, "Users")); FD shared(child(users.value, "Shared"));
    for (int fd : {slash.value, users.value}) {
        auto st = info(fd); require(st.st_uid == 0 && (st.st_mode & 0022) == 0, "Unsafe runtime ancestor");
    }
    auto sharedStat = info(shared.value);
    require(sharedStat.st_uid == 0 && (sharedStat.st_mode & S_ISVTX), "Unsafe shared runtime parent");
    std::string baseName = "RAMNestNative-" + std::to_string(r.uid);
    if (r.operation == "reserve") {
        if (mkdirat(shared.value, baseName.c_str(), 0755) != 0) require(errno == EEXIST, "Cannot create fixed runtime parent");
    }
    FD base(child(shared.value, baseName)); owned(base.value, 0755); internal(base.value, shared.value);
    if (r.operation == "reserve") {
        require(mkdirat(base.value, r.session.c_str(), 0755) == 0, "Session slot already exists; refusing adoption");
        FD slot(child(base.value, r.session)); owned(slot.value, 0755); internal(slot.value, shared.value);
        require(mkdirat(slot.value, "mount", 0755) == 0, "Cannot create slot mountpoint");
        FD mount(child(slot.value, "mount")); owned(mount.value, 0755); internal(mount.value, shared.value);
        FD lock(openat(slot.value, "control.lock", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0600));
        require(fsync(slot.value) == 0 && fsync(base.value) == 0, "Cannot sync native reservation");
        auto b = info(base.value), m = info(mount.value);
        r.rootDevice = device(b.st_dev); r.rootInode = b.st_ino; r.mountDevice = device(m.st_dev); r.mountInode = m.st_ino;
        writeAuthority(lock.value, r);
        std::cout << "OK\t" << device(b.st_dev) << '\t' << b.st_ino << '\t' << device(m.st_dev) << '\t' << m.st_ino << '\n'; return;
    }
    identity(base.value, r.rootDevice, r.rootInode);
    struct stat slotStat{};
    if (r.operation == "release" && fstatat(base.value, r.session.c_str(), &slotStat, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) {
        std::cout << "OK\n"; return; // Completed release before journal replacement.
    }
    FD slot(child(base.value, r.session)); owned(slot.value, 0755); internal(slot.value, shared.value);
    // Resume only an already-empty completed release after its lock was retired.
    struct stat lockStat{};
    if (r.operation == "release" && fstatat(slot.value, "control.lock", &lockStat, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) {
        empty(slot.value);
        require(unlinkat(base.value, r.session.c_str(), AT_REMOVEDIR) == 0 && fsync(base.value) == 0, "Cannot finish empty native slot release");
        std::cout << "OK\n"; return;
    }
    FD lock(openat(slot.value, "control.lock", O_RDWR | O_NOFOLLOW | O_CLOEXEC));
    auto l = info(lock.value); require(S_ISREG(l.st_mode) && l.st_uid == 0 && l.st_nlink == 1 && (l.st_mode & 07777) == 0600, "Invalid slot control lock");
    require(flock(lock.value, LOCK_EX) == 0, "Cannot serialize native control");
    readAuthority(lock.value).validate(r);
    struct statfs* mounts = nullptr; int count = getmntinfo(&mounts, MNT_NOWAIT);
    require(count > 0 && mounts, "Cannot inspect mount table");
    for (int i = 0; i < count; ++i) {
        auto path = std::string(mounts[i].f_mntonname);
        require(path.rfind(r.mount() + "/", 0) != 0, "Nested mount present; refusing native control");
        if (r.operation == "release") require(path != r.mount(), "Native mount remains present; release refused");
    }
    bool preserveNobrowse = false;
    {
        struct stat named{};
        if (r.operation == "release" && fstatat(slot.value, "mount", &named, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) {
            // Crash after removing the bound empty mountpoint but before lock/slot.
            require(unlinkat(slot.value, "control.lock", 0) == 0, "Cannot finish native lock release");
            empty(slot.value); require(unlinkat(base.value, r.session.c_str(), AT_REMOVEDIR) == 0 && fsync(base.value) == 0, "Cannot finish native slot release");
            std::cout << "OK\n"; return;
        }
        FD mount(child(slot.value, "mount"));
        if (r.operation == "mount" || r.operation == "release") {
            owned(mount.value, 0755); internal(mount.value, shared.value);
            identity(mount.value, r.mountDevice, r.mountInode); empty(mount.value);
        } else { auto fs = filesystem(mount.value); native(fs, r, r.operation == "unmount" ? 1 : -1); preserveNobrowse = fs.f_flags & MNT_DONTBROWSE; }
    }
    if (r.operation == "release") {
        // Only these exact, bound, empty objects. No recursive cleanup.
        require(unlinkat(slot.value, "mount", AT_REMOVEDIR) == 0 && unlinkat(slot.value, "control.lock", 0) == 0, "Cannot retire empty runtime slot");
        empty(slot.value); require(unlinkat(base.value, r.session.c_str(), AT_REMOVEDIR) == 0 && fsync(base.value) == 0, "Cannot retire empty session directory");
    } else if (r.operation == "mount") {
        run("/sbin/mount_tmpfs", {"-e", "-o", r.nobrowse ? "nobrowse,nosuid,nodev" : "nosuid,nodev", "-s", std::to_string(r.capacity), r.mount()});
        FD mount(child(slot.value, "mount")); auto fs = filesystem(mount.value);
        r.fsid0 = static_cast<uint32_t>(fs.f_fsid.val[0]); r.fsid1 = static_cast<uint32_t>(fs.f_fsid.val[1]); native(fs, r, 0);
        // These are newly created directories inside the just-mounted tmpfs.
        // Never chown any caller-supplied path or an existing user object.
        require(info(mount.value).st_uid == 0, "New native mount root is not root-owned");
        require(fchmod(mount.value, 0755) == 0, "Cannot protect native mount root");
        require(mkdirat(mount.value, "tree", 0700) == 0, "Cannot create native user workspace");
        FD tree(child(mount.value, "tree"));
        require(fchown(tree.value, r.uid, user->pw_gid) == 0, "Cannot hand off new workspace");
        writeAuthority(lock.value, r);
        std::cout << "OK\t" << r.fsid0 << '\t' << r.fsid1 << '\t' << uint64_t(fs.f_blocks) * fs.f_bsize << '\n'; return;
    } else if (r.operation == "readonly" || r.operation == "freeze" || r.operation == "thaw") {
        std::string options = r.operation != "thaw" ? "update,rdonly,nosuid,nodev" : "update,rw,nosuid,nodev";
        if (preserveNobrowse) options += ",nobrowse";
        run("/sbin/mount_tmpfs", {"-e", "-o", options, "-s", std::to_string(r.capacity), r.mount()});
        FD mount(child(slot.value, "mount")); native(filesystem(mount.value), r, r.operation != "thaw" ? 1 : 0);
        if (r.operation == "freeze") {
            scanMappings(r);
            native(filesystem(mount.value), r, 1);
            std::cout << "OK\t" << quiescenceReceipt << '\t' << r.fsid0 << '\t' << r.fsid1 << '\n'; return;
        }
    } else {
        run("/sbin/umount", {r.mount()}); // Never -f. Pin is deliberately retired first.
        FD mount(child(slot.value, "mount")); identity(mount.value, r.mountDevice, r.mountInode); internal(mount.value, shared.value);
    }
    std::cout << "OK\n";
}

bool sameMount(int fd, const Request& r) {
    try {
        native(filesystem(fd), r);
        FD current(open(r.mount().c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); native(filesystem(current.value), r);
        return true;
    } catch (...) { return false; }
}
void closeInheritedDescriptors() {
    const int limit = getdtablesize();
    for (int fd = 3; fd < limit; ++fd) close(fd);
}
void retireSaveChild(pid_t& saving) {
    if (saving <= 0) return;
    auto pollChild = [&] {
        pid_t result;
        do { result = waitpid(saving, nullptr, WNOHANG); } while (result < 0 && errno == EINTR);
        return result;
    };
    // An unreaped child PID cannot be reused. Never signal an IPC-supplied PID.
    if (pollChild() == 0) {
        kill(saving, SIGTERM);
        bool reaped = false;
        for (int i = 0; i < 20; ++i) {
            if (pollChild() != 0) { reaped = true; break; }
            usleep(10000);
        }
        if (!reaped) { kill(saving, SIGKILL); while (waitpid(saving, nullptr, 0) < 0 && errno == EINTR) {} }
    }
    saving = 0;
}
void pin(const std::vector<std::string>& a) {
    require(a.size() == 8, "Invalid unprivileged pin arguments");
    Request r; auto uid = number(a[0]); require(uid == getuid() && uid >= 501 && geteuid() == getuid(), "Pin must run as its ordinary user");
    r.uid = static_cast<uint32_t>(uid); r.session = a[1]; require(uuid(r.session), "Invalid pin session");
    auto x = number(a[2]), y = number(a[3]); require(x <= UINT32_MAX && y <= UINT32_MAX, "Invalid pin fsid"); r.fsid0 = x; r.fsid1 = y;
    const auto& socketPath = a[4]; const auto& folder = a[5]; const auto& cli = a[6]; const auto& store = a[7];
    require(uuid(folder) && !cli.empty() && cli.front() == '/' && !store.empty() && store.front() == '/', "Invalid coordinator arguments");
    require(socketPath.size() < sizeof(sockaddr_un::sun_path) && socketPath.find('\n') == std::string::npos, "Invalid pin socket");
    auto slash = socketPath.rfind('/'); require(slash != std::string::npos && (socketPath.substr(slash + 1).size() == 41 && uuid(socketPath.substr(slash + 1, 36)) && socketPath.substr(socketPath.size() - 5) == ".sock"), "Socket does not bind session");
    std::string parent = socketPath.substr(0, slash);
    require(parent.rfind("/private/tmp/ramnest-" + std::to_string(uid) + "-", 0) == 0 && parent.find('/', 13) == std::string::npos, "Invalid private socket parent");
    FD directory(open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); auto ds = info(directory.value);
    require(ds.st_uid == uid && (ds.st_mode & 07777) == 0700, "Socket parent is not private");
    // Protected fixed native ancestors are revalidated even in the ordinary-user pin.
    FD root(open(r.root().c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)); owned(root.value, 0755);
    FD slot(child(root.value, r.session)); owned(slot.value, 0755);
    FD mount(child(slot.value, "mount")); native(filesystem(mount.value), r);
    FD server(socket(AF_UNIX, SOCK_STREAM, 0)); fcntl(server.value, F_SETFD, FD_CLOEXEC);
    sockaddr_un address{}; address.sun_family = AF_UNIX; strlcpy(address.sun_path, socketPath.c_str(), sizeof(address.sun_path));
    require(bind(server.value, reinterpret_cast<sockaddr*>(&address), sizeof(address)) == 0, "Cannot reserve new pin socket");
    require(chmod(socketPath.c_str(), 0600) == 0 && listen(server.value, 8) == 0, "Cannot protect pin socket");
    const auto socketIdentity = info(directory.value);
    struct stat boundSocket{};
    require(fstatat(directory.value, socketPath.substr(slash + 1).c_str(), &boundSocket, AT_SYMLINK_NOFOLLOW) == 0 && S_ISSOCK(boundSocket.st_mode), "Pin socket parent changed during bind");
    FD namedParent(open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
    identity(namedParent.value, device(socketIdentity.st_dev), socketIdentity.st_ino);
    PeriodicSchedule schedule; pid_t saving = 0;
    auto nextSave = std::chrono::steady_clock::now();
    bool retire = false;
    while (!retire) {
        if (saving > 0 && waitpid(saving, nullptr, WNOHANG) == saving) saving = 0;
        if (schedule.minutes > 0 && saving == 0 && std::chrono::steady_clock::now() >= nextSave) {
            nextSave = std::chrono::steady_clock::now() + std::chrono::minutes(schedule.minutes);
            if (sameMount(mount.value, r)) {
                // Always ordinary-user execution. CLI locks serialize saves/ejects.
                saving = fork();
                if (saving == 0) {
                    auto first = std::to_string(r.fsid0), second = std::to_string(r.fsid1), minutes = std::to_string(schedule.minutes);
                    closeInheritedDescriptors();
                    execl(cli.c_str(), cli.c_str(), "--store", store.c_str(), "internal-periodic-save", folder.c_str(), r.session.c_str(),
                          first.c_str(), second.c_str(), schedule.verification.c_str(), minutes.c_str(), schedule.authorization.c_str(), socketPath.c_str(), static_cast<char*>(nullptr)); _exit(127);
                }
                if (saving < 0) saving = 0;
            }
        }
        fd_set set; FD_ZERO(&set); FD_SET(server.value, &set); timeval wait{1, 0};
        int ready = select(server.value + 1, &set, nullptr, nullptr, &wait); if (ready < 0 && errno == EINTR) continue;
        require(ready >= 0, "Pin polling failed"); if (ready == 0) continue;
        int clientFD = accept(server.value, nullptr, nullptr); if (clientFD < 0) continue;
        FD client(clientFD); fcntl(client.value, F_SETFD, FD_CLOEXEC);
        uid_t peer; gid_t group;
        if (getpeereid(client.value, &peer, &group) != 0 || peer != uid) continue;
        timeval timeout{2, 0}; setsockopt(client.value, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)); setsockopt(client.value, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        int noSignal = 1; setsockopt(client.value, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, sizeof(noSignal));
        std::string command; char c; bool complete = false;
        while (command.size() < 8192 && read(client.value, &c, 1) == 1) { if (c == '\n') { complete = true; break; } if (c == '\0') break; command += c; }
        std::string reply = "ERR\t22\n";
        if (complete) {
            const bool live = sameMount(mount.value, r);
            if (command == "status") {
                auto fs = filesystem(mount.value); uint64_t used = (uint64_t(fs.f_blocks) - std::min(uint64_t(fs.f_blocks), uint64_t(fs.f_bfree))) * fs.f_bsize;
                reply = "OK\t" + folder + "\t" + std::to_string(getpid()) + "\t" + (live ? "mounted" : "lost") + "\t" + std::to_string(live ? used : 0) + "\t" + std::to_string(uint64_t(fs.f_blocks) * fs.f_bsize) + "\t" + (live && !(fs.f_flags & MNT_RDONLY) ? "active" : "guarded") + "\n";
            } else if (command == "capabilities") reply = "OK\tnative-tmpfs-v1\n";
            else if (command == "retire") { retire = true; schedule = {}; retireSaveChild(saving); close(mount.value); mount.value = -1; reply = "OK\n"; }
            else if (command.rfind("period\t", 0) == 0) {
                try {
                    auto next = PeriodicSchedule::parse(command);
                    retireSaveChild(saving); schedule = next;
                    nextSave = std::chrono::steady_clock::now() + std::chrono::minutes(schedule.minutes); reply = "OK\n";
                } catch (...) { }
            }
        }
        size_t sent = 0;
        while (sent < reply.size()) { ssize_t n = write(client.value, reply.data() + sent, reply.size() - sent); if (n <= 0) break; sent += size_t(n); }
    }
    // Only remove the socket this process bound in its pinned private parent.
    struct stat st{}; if (fstatat(directory.value, socketPath.substr(slash + 1).c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0 && S_ISSOCK(st.st_mode) && st.st_uid == uid && st.st_ino == boundSocket.st_ino && st.st_dev == boundSocket.st_dev)
        unlinkat(directory.value, socketPath.substr(slash + 1).c_str(), 0);
}
}
int main(int argc, char** argv) {
    try {
        umask(0022);
        std::vector<std::string> a(argv + 1, argv + argc);
        if (a == std::vector<std::string>{"--capabilities"}) { std::cout << protocol << '\n'; return 0; }
        bool daemon = !a.empty() && a[0] == "--daemonize";
        if (daemon) { a.erase(a.begin()); require(!a.empty() && a[0] == "--pin-v1" && getuid() != 0, "Only the unprivileged pin may detach"); }
        require(!a.empty(), "Missing native helper mode"); auto mode = a[0]; a.erase(a.begin());
        if (mode == "--native-v1") { require(!daemon, "Privileged operations cannot detach"); privileged(Request::parse(a)); }
        else if (mode == "--pin-v1") {
            require(getuid() != 0 && geteuid() == getuid(), "No privileged pin or IPC is allowed");
            if (daemon) { pid_t pid = fork(); require(pid >= 0, "Cannot detach pin"); if (pid > 0) return 0; require(setsid() >= 0, "Cannot start pin session"); closeInheritedDescriptors(); int null = open("/dev/null", O_RDWR); require(null >= 0, "Cannot detach stdio"); for (int i = 0; i < 3; ++i) dup2(null, i); if (null > 2) close(null); }
            pin(a);
        } else throw std::runtime_error("Unsupported native helper mode");
        return 0;
    } catch (const std::exception& e) { std::cerr << "ramnest-helper: " << e.what() << '\n'; return 6; }
}
