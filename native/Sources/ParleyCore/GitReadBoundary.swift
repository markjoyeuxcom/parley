import Foundation

/// Every Git command Parley runs on this Mac to read a repository goes
/// through here: delegation Git facts, the pane Git context, worktree
/// discovery, board facts, cleanup and merge previews, context Git Diff,
/// review drafts and container Git access.
///
/// A repository's own configuration and attributes can name programs for
/// Git to start: clean, smudge and process filters, textconv and external
/// diff drivers, an fsmonitor hook, a lazy fetch from a promisor remote, a
/// status child for each submodule. An agent can write that configuration,
/// and a container pane always can, because its project mount includes the
/// checkout's `.git` (or the reviewed shared Git directory of a linked
/// worktree). Parley's reads run without anyone's approval, some on a timer
/// and some when an agent reports, so they must never start those programs.
/// The 22 September 2026 review reproduced a container agent getting its
/// clean filter run on this Mac by running `parley done`.
///
/// Before either layer, `realGit(for:environment:)` resolves Apple's
/// `/usr/bin/git` shim to the selected developer directory's Git from the
/// filesystem alone, so the guard execs Git itself: the shim forks
/// `xcodebuild -find git` on a cold xcrun cache when a full Xcode is
/// selected, and under the guard that fork fails before Git runs.
///
/// Two layers:
/// 1. The read runs under a fixed `/bin/bash` guard that lowers the process
///    limit to one and then `exec`s Git in place. Git itself runs, but
///    every `fork` it attempts fails, so no filter, driver, hook or fetch can
///    start however and whenever the configuration changes, including a
///    change made between the driver listing below and the read itself.
///    The script is a constant; Git's path and arguments reach it as
///    positional parameters and the shell never parses them.
/// 2. Before a command that may read file content (status and diff), every
///    filter driver named by any configuration Git would read there has its
///    clean, smudge and process commands set to empty and `required` set to
///    false for that one read, through `GIT_CONFIG_*` so a driver name
///    containing `=` survives. That is what keeps the read working: a
///    required filter (git-lfs installs one) would otherwise make Git stop
///    when the guard refuses its fork. An edited file under a filter is
///    therefore compared as raw bytes and may be reported modified.
///
/// Callers add `statusArguments` or `diffArguments` because textconv and
/// external diff failures are fatal and a dirty-submodule check needs a
/// child Git; with those, a submodule is reported only when its recorded
/// commit changed. Git operations the person confirms (creating, removing
/// or integrating a worktree, deleting a branch) are not reads and do not
/// run inside the guard; removal alone takes `filterOverrides`, for the
/// status Git runs inside `git worktree remove`.
public enum GitReadBoundary {
    public static let shell = URL(fileURLWithPath: "/bin/bash")
    /// Lowers the soft and hard process limits to one, then replaces the
    /// shell with Git. `$@` is Git's path followed by its arguments.
    public static let script = #"ulimit -H -S -u 1 && exec "$@""#
    /// `$0` inside the guard; it appears only in the shell's own errors.
    public static let scriptName = "parley-git-read"

    /// Added to a status command: submodules are compared by recorded commit
    /// only, which needs no child Git.
    public static let statusArguments = ["--ignore-submodules=dirty"]
    /// Added to a diff command: no textconv, no external diff, submodules by
    /// recorded commit only and shown as a short commit line.
    public static let diffArguments = ["--no-textconv", "--no-ext-diff", "--ignore-submodules=dirty", "--submodule=short"]

    /// The Worktrees window's disclosure: facts are read safely, and the
    /// actions the person confirms are Git itself.
    public static let worktreesDisclosure = "Parley reads these facts with the repository's filters and diff drivers off, through a Git that cannot start another program. Agents, and container panes using this repository, can change its Git configuration and hooks; New Worktree, Remove, Prune, Delete branch and Integrate run Git itself, which can start programs that configuration names."

    /// Every container review's disclosure, whether or not a shared Git
    /// directory is mounted.
    public static let containerDisclosure = "Git configuration: when this folder's repository keeps its .git inside the folder, or through the shared Git mount above, the container can change that repository's Git configuration, hooks and attributes. Parley records no Git facts for this pane's delegations, and its own Git reads of the repository turn filters and diff drivers off and cannot start another program. Git that you or a host pane run there later, and Parley's worktree actions, use whatever configuration the container left."

    /// At most this many filter drivers are neutralised for one read. Past
    /// it the guard alone refuses their programs; a required one then makes
    /// the read fail rather than run anything.
    public static let maximumNeutralizedDrivers = 64

    /// The environment for a read. Every inherited `GIT_*` variable could
    /// redirect `-C` or reintroduce configuration, and the shell startup
    /// variables could change what the guard's shell does before it reaches
    /// Git, so none of them survives. Locks, prompts, pagers and lazy
    /// fetches are then turned off.
    public static func environment(_ base: [String: String]) -> [String: String] {
        var result = base.filter { key, _ in
            !key.hasPrefix("GIT_") && !key.hasPrefix("BASH_") && !["ENV", "SHELLOPTS", "BASHOPTS", "CDPATH"].contains(key)
        }
        result["GIT_OPTIONAL_LOCKS"] = "0"
        result["GIT_TERMINAL_PROMPT"] = "0"
        result["GIT_NO_LAZY_FETCH"] = "1"
        result["GIT_PAGER"] = "cat"
        result["PAGER"] = "cat"
        result["LC_ALL"] = "C"
        return result
    }

    /// Apple's Git shim. `/usr/bin/git` is not Git: it asks libxcselect for
    /// the selected developer directory and runs that directory's Git. With a
    /// warm xcrun cache it `exec`s it in place; with a cold cache and a full
    /// Xcode selected it forks `xcodebuild -find git` first, which the guard
    /// refuses, so the read fails before Git runs (seen on the hosted CI image,
    /// 10 October 2026, and possible on any Mac with Xcode selected after a
    /// boot or a TMPDIR change).
    public static let shim = URL(fileURLWithPath: "/usr/bin/git")
    /// The link `xcode-select` maintains to the selected developer directory.
    public static let developerDirectoryLink = "/var/db/xcode_select_link"
    /// Where the Command Line Tools install, selected or not.
    public static let commandLineToolsDirectory = "/Library/Developer/CommandLineTools"

    /// The Git the guard execs for `git`. The shim is resolved here, outside
    /// the guard and from the filesystem alone, the way xcrun resolves it:
    /// `DEVELOPER_DIR` when set to an absolute path (the directory itself or
    /// the Xcode bundle it lives in), then the developer directory
    /// `xcode-select` links, then the Command Line Tools, taking the first
    /// whose `usr/bin/git` is an executable regular file, symlinks followed;
    /// the path is returned as named, so the guard's argv shows which
    /// developer directory answered.
    /// Nothing here reads the repository, so nothing an agent or container
    /// writes can steer it. When no candidate exists the shim is kept, and
    /// the read reports whatever the shim then does. Any other `git` is run
    /// as named.
    public static func realGit(
        for git: URL,
        environment: [String: String],
        isExecutableRegularFile: (String) -> Bool = isExecutableRegularFile
    ) -> URL {
        guard git.path == shim.path else { return git }
        var developerDirectories: [String] = []
        if let developerDirectory = environment["DEVELOPER_DIR"], developerDirectory.hasPrefix("/") {
            developerDirectories.append(developerDirectory)
            developerDirectories.append(developerDirectory + "/Contents/Developer")
        }
        developerDirectories.append(developerDirectoryLink)
        developerDirectories.append(commandLineToolsDirectory)
        for directory in developerDirectories {
            let candidate = directory + "/usr/bin/git"
            if isExecutableRegularFile(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return git
    }

    /// Whether `path`, symlinks followed, is a regular file this process may
    /// execute.
    public static func isExecutableRegularFile(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let type = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.type] as? FileAttributeType,
              type == .typeRegular else { return false }
        return FileManager.default.isExecutableFile(atPath: resolved)
    }

    /// The executable and argv that run `git <arguments>` unable to start
    /// another process.
    public static func invocation(git: URL, arguments: [String]) -> (executable: URL, arguments: [String]) {
        (shell, ["-c", script, scriptName, git.path] + arguments)
    }

    /// The Git arguments inside a guarded invocation, or nil when `arguments`
    /// is not one. Checks use it to read what Git was asked to do.
    public static func gitArguments(inInvocation arguments: [String]) -> [String]? {
        guard arguments.count >= 4, Array(arguments.prefix(3)) == ["-c", script, scriptName] else { return nil }
        return Array(arguments.dropFirst(4))
    }

    public static func run(
        git: URL,
        arguments: [String],
        environment: [String: String],
        runner: any CommandRunning
    ) throws -> CommandOutput {
        let invocation = invocation(git: realGit(for: git, environment: environment), arguments: arguments)
        return try runner.run(executable: invocation.executable, arguments: invocation.arguments, environment: environment, input: nil)
    }

    /// `environment` plus `filterOverrides` for `folder`.
    public static func neutralizingFilters(
        in folder: String,
        git: URL,
        environment: [String: String],
        runner: any CommandRunning
    ) -> [String: String] {
        environment.merging(filterOverrides(in: folder, git: git, environment: environment, runner: runner)) { _, override in override }
    }

    /// `GIT_CONFIG_*` entries that turn off every filter driver any
    /// configuration Git reads in `folder` defines, from system to worktree
    /// scope and through includes. The listing itself runs guarded with
    /// `environment`. When it fails nothing is returned: the guard still
    /// stops every program, and the read that follows reports its own failure.
    public static func filterOverrides(
        in folder: String,
        git: URL,
        environment: [String: String],
        runner: any CommandRunning
    ) -> [String: String] {
        guard let listing = try? run(
            git: git,
            arguments: ["-C", folder, "-c", "core.fsmonitor=false", "config", "--list", "--name-only", "-z"],
            environment: environment,
            runner: runner
        ), listing.status == 0 else { return [:] }
        return overrides(disabling: filterDrivers(inConfigNames: listing.stdout))
    }

    /// Driver names from `git config --list --name-only -z`: the subsection
    /// of every `filter.<driver>.<key>`, in first-seen order, without
    /// duplicates. A name that is not valid UTF-8 or carries a control
    /// character cannot be written back exactly, so it is left to the guard.
    public static func filterDrivers(inConfigNames output: Data) -> [String] {
        var drivers: [String] = []
        var seen: Set<String> = []
        for field in output.split(separator: 0) {
            guard let name = String(data: Data(field), encoding: .utf8), name.hasPrefix("filter.") else { continue }
            let rest = name.dropFirst("filter.".count)
            guard let lastDot = rest.lastIndex(of: ".") else { continue }
            let driver = String(rest[..<lastDot])
            guard !driver.isEmpty,
                  !driver.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  seen.insert(driver).inserted else { continue }
            drivers.append(driver)
            if drivers.count == maximumNeutralizedDrivers { break }
        }
        return drivers
    }

    /// Command-scope configuration, which Git reads last, setting each
    /// driver's clean, smudge and process commands to empty (Git runs none
    /// of them then) and `required` to false. The environment these join
    /// must not already carry `GIT_CONFIG_*`; `environment(_:)` removes them.
    public static func overrides(disabling drivers: [String]) -> [String: String] {
        guard !drivers.isEmpty else { return [:] }
        var result: [String: String] = [:]
        var index = 0
        for driver in drivers {
            for (key, value) in [("clean", ""), ("smudge", ""), ("process", ""), ("required", "false")] {
                result["GIT_CONFIG_KEY_\(index)"] = "filter.\(driver).\(key)"
                result["GIT_CONFIG_VALUE_\(index)"] = value
                index += 1
            }
        }
        result["GIT_CONFIG_COUNT"] = String(index)
        return result
    }
}
