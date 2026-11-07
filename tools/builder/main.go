// Command onegun-build builds Super Tenet into a single self-contained
// executable for Linux or Windows.
//
//	onegun-build                  build for the OS you're on
//	onegun-build -target windows  or: linux, all
//	onegun-build play [-- ARGS]   build for this OS if the code changed since
//	                              the last build, then start the game (ARGS
//	                              are passed to it)
//
// Outputs build/linux/SuperTenet.x86_64 and build/windows/SuperTenet.exe.
//
// It has no runtime dependencies (no Python, unzip or curl). Godot comes from
// $GODOT, or from PATH if it is 4.7.x; otherwise the official Godot 4.7.2 is
// downloaded once into a cache folder and run in self-contained mode, so it
// writes nothing outside that folder. Export templates are read straight out
// of Godot's 1.3 GB all-platform bundle with HTTP range requests, so only the
// ~35 MB per platform you build for is downloaded.
package main

import (
	"archive/zip"
	"bytes"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"
)

const (
	godotVersion = "4.7.2"
	series       = "4.7"
	releases     = "https://github.com/godotengine/godot/releases/download/" + godotVersion + "-stable"
)

type target struct {
	preset, template, out string
}

var targets = map[string]target{
	"linux":   {"Linux", "linux_release.x86_64", filepath.Join("build", "linux", "SuperTenet.x86_64")},
	"windows": {"Windows Desktop", "windows_release_x86_64.exe", filepath.Join("build", "windows", "SuperTenet.exe")},
}

// Godot editor downloads that can run the export, by GOOS/GOARCH of this machine.
var editors = map[string][2]string{ // zip name suffix, executable suffix
	"linux/amd64":   {"linux.x86_64.zip", "linux.x86_64"},
	"linux/arm64":   {"linux.arm64.zip", "linux.arm64"},
	"windows/amd64": {"win64.exe.zip", "win64_console.exe"},
	"windows/arm64": {"windows_arm64.exe.zip", "windows_arm64_console.exe"},
}

var client = &http.Client{Timeout: 10 * time.Minute}

func logf(format string, args ...any) {
	fmt.Printf("[build] "+format+"\n", args...)
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "[build] error: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	mode := "build"
	args := os.Args[1:]
	if len(args) > 0 && (args[0] == "play" || args[0] == "build") {
		mode, args = args[0], args[1:]
	}
	fs := flag.NewFlagSet("onegun-build", flag.ExitOnError)
	which := fs.String("target", "auto", "what to build: auto (this OS), linux, windows or all")
	project := fs.String("project", "", "project folder (default: found from the current folder)")
	force := fs.Bool("force", false, "play: rebuild even if the build is up to date")
	_ = fs.Parse(args)

	root := *project
	if root == "" {
		root = findProject()
	}

	if mode == "play" {
		play(root, *force, fs.Args())
		return
	}
	names, err := pickTargets(*which)
	if err != nil {
		fail("%v", err)
	}
	build(root, names)
}

// play builds the game for this OS when the sources are newer than the
// last build, then runs it with `gameArgs`.
func play(root string, force bool, gameArgs []string) {
	names, err := pickTargets("auto")
	if err != nil {
		fail("%v", err)
	}
	exe := filepath.Join(root, targets[names[0]].out)
	if force || isStale(root, exe) {
		build(root, names)
	} else {
		logf("Build is up to date: %s", targets[names[0]].out)
	}
	logf("Starting Super Tenet")
	cmd := exec.Command(exe, gameArgs...)
	cmd.Dir = filepath.Dir(exe)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			os.Exit(exitErr.ExitCode())
		}
		fail("couldn't start the game: %v", err)
	}
}

// isStale reports whether any game source file is newer than `exe` (or
// `exe` doesn't exist yet). Tooling, docs and build output don't count.
func isStale(root, exe string) bool {
	info, err := os.Stat(exe)
	if err != nil {
		return true
	}
	built := info.ModTime()
	skip := map[string]bool{".godot": true, ".git": true, "build": true, "tools": true, "docs": true,
		"game-style": true, "server": true, "tests": true}
	stale := false
	_ = filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil || stale {
			return filepath.SkipDir
		}
		if d.IsDir() {
			if path != root && skip[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if fi, err := d.Info(); err == nil && fi.ModTime().After(built) {
			stale = true
		}
		return nil
	})
	return stale
}

// build exports the given targets with Godot (fetching Godot and the
// export templates first if needed).
func build(root string, names []string) {
	godot, version, selfContained := findGodot()
	logf("Using Godot %s at %s", version, godot)

	var wanted []string
	for _, n := range names {
		wanted = append(wanted, targets[n].template)
	}
	if err := ensureTemplates(templateDir(godot, version, selfContained), version, wanted); err != nil {
		fail("fetching export templates: %v", err)
	}

	// Keep Godot from scanning build output as project files.
	_ = os.MkdirAll(filepath.Join(root, "build"), 0o755)
	_ = os.WriteFile(filepath.Join(root, "build", ".gdignore"), nil, 0o644)

	_ = exec.Command(godot, "--headless", "--path", root, "--import").Run()
	for _, n := range names {
		t := targets[n]
		out := filepath.Join(root, t.out)
		_ = os.MkdirAll(filepath.Dir(out), 0o755)
		_ = os.Remove(out)
		logf("Exporting %s ...", n)
		cmd := exec.Command(godot, "--headless", "--path", root, "--export-release", t.preset, out)
		output, err := cmd.CombinedOutput()
		if _, statErr := os.Stat(out); err != nil || statErr != nil {
			tail := output
			if len(tail) > 4000 {
				tail = tail[len(tail)-4000:]
			}
			fmt.Println(string(tail))
			fail("export for %s failed", n)
		}
		if n == "linux" {
			_ = os.Chmod(out, 0o755)
		}
		info, _ := os.Stat(out)
		logf("Built %s (%d MB)", t.out, info.Size()/1_000_000)
	}
}

func pickTargets(which string) ([]string, error) {
	switch which {
	case "all":
		return []string{"linux", "windows"}, nil
	case "linux", "windows":
		return []string{which}, nil
	case "auto":
		switch runtime.GOOS {
		case "linux", "windows":
			return []string{runtime.GOOS}, nil
		}
		return nil, fmt.Errorf("there's no %s build yet; use -target linux or -target windows to cross-build", runtime.GOOS)
	}
	return nil, fmt.Errorf("unknown target %q (use auto, linux, windows or all)", which)
}

// findProject walks up from the current folder to the one holding project.godot.
func findProject() string {
	dir, _ := os.Getwd()
	for {
		if _, err := os.Stat(filepath.Join(dir, "project.godot")); err == nil {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			fail("can't find project.godot; run this from the game folder or pass -project")
		}
		dir = parent
	}
}

// --- Godot ------------------------------------------------------------------

func godotVersionOf(exe string) string {
	out, err := exec.Command(exe, "--version").Output()
	if err != nil {
		return ""
	}
	lines := strings.Fields(strings.TrimSpace(string(out)))
	if len(lines) == 0 {
		return ""
	}
	var nums []string
	for _, p := range strings.Split(lines[len(lines)-1], ".") {
		if p == "" || strings.Trim(p, "0123456789") != "" || len(nums) == 3 {
			break
		}
		nums = append(nums, p)
	}
	return strings.Join(nums, ".")
}

func findGodot() (path, version string, selfContained bool) {
	if exe := os.Getenv("GODOT"); exe != "" {
		v := godotVersionOf(exe)
		if !strings.HasPrefix(v, series) {
			fail("GODOT=%s is version %q, this project needs %s.x", exe, v, series)
		}
		return exe, v, isSelfContained(exe)
	}
	for _, name := range []string{"godot", "godot4"} {
		if exe, err := exec.LookPath(name); err == nil {
			if v := godotVersionOf(exe); strings.HasPrefix(v, series) {
				return exe, v, isSelfContained(exe)
			} else {
				logf("Ignoring %s (version %q, this project needs %s.x)", exe, v, series)
			}
		}
	}
	return downloadGodot()
}

func isSelfContained(exe string) bool {
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	dir := filepath.Dir(exe)
	for _, marker := range []string{"._sc_", "_sc_"} {
		if _, err := os.Stat(filepath.Join(dir, marker)); err == nil {
			return true
		}
	}
	return false
}

func cacheDir() string {
	base, err := os.UserCacheDir()
	if err != nil {
		base = os.TempDir()
	}
	return filepath.Join(base, "one-gun-one-bullet")
}

func downloadGodot() (string, string, bool) {
	key := runtime.GOOS + "/" + runtime.GOARCH
	ed, ok := editors[key]
	if !ok {
		fail("can't fetch Godot for %s automatically; install Godot %s and set GODOT=/path/to/godot", key, godotVersion)
	}
	folder := filepath.Join(cacheDir(), "godot-"+godotVersion)
	exe := filepath.Join(folder, "Godot_v"+godotVersion+"-stable_"+ed[1])
	if _, err := os.Stat(exe); err == nil {
		return exe, godotVersion, true
	}
	url := releases + "/Godot_v" + godotVersion + "-stable_" + ed[0]
	logf("Downloading Godot %s for %s (about 80 MB) into %s", godotVersion, key, folder)
	data, err := download(url)
	if err != nil {
		fail("downloading Godot: %v", err)
	}
	zr, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		fail("reading Godot download: %v", err)
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		fail("%v", err)
	}
	for _, f := range zr.File {
		if f.FileInfo().IsDir() || strings.Contains(f.Name, "..") {
			continue
		}
		dest := filepath.Join(folder, filepath.FromSlash(f.Name))
		if err := extract(f, dest, 0o755); err != nil {
			fail("unpacking Godot: %v", err)
		}
	}
	// Self-contained mode: Godot keeps its settings and export templates in
	// editor_data/ next to itself instead of in your user folders.
	_ = os.WriteFile(filepath.Join(folder, "._sc_"), nil, 0o644)
	return exe, godotVersion, true
}

func download(url string) ([]byte, error) {
	resp, err := client.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	return io.ReadAll(resp.Body)
}

func extract(f *zip.File, dest string, mode os.FileMode) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o755); err != nil {
		return err
	}
	src, err := f.Open()
	if err != nil {
		return err
	}
	defer src.Close()
	tmp := dest + ".part"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, src); err != nil {
		out.Close()
		return err
	}
	if err := out.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

func templateDir(godot, version string, selfContained bool) string {
	var base string
	switch {
	case selfContained:
		if real, err := filepath.EvalSymlinks(godot); err == nil {
			godot = real
		}
		base = filepath.Join(filepath.Dir(godot), "editor_data")
	case runtime.GOOS == "windows":
		base = filepath.Join(os.Getenv("APPDATA"), "Godot")
	case runtime.GOOS == "darwin":
		home, _ := os.UserHomeDir()
		base = filepath.Join(home, "Library", "Application Support", "Godot")
	default:
		data := os.Getenv("XDG_DATA_HOME")
		if data == "" {
			home, _ := os.UserHomeDir()
			data = filepath.Join(home, ".local", "share")
		}
		base = filepath.Join(data, "godot")
	}
	return filepath.Join(base, "export_templates", version+".stable")
}

// --- Export templates from the remote bundle ----------------------------------

func ensureTemplates(dest, version string, names []string) error {
	var missing []string
	for _, n := range append(names, "version.txt") {
		if _, err := os.Stat(filepath.Join(dest, n)); err != nil {
			missing = append(missing, n)
		}
	}
	if len(missing) == 0 {
		return nil
	}
	sort.Strings(missing)
	url := "https://github.com/godotengine/godot/releases/download/" + version + "-stable/Godot_v" +
		version + "-stable_export_templates.tpz"
	logf("Fetching export templates: %s", strings.Join(missing, ", "))
	remote, err := openRemote(url)
	if err != nil {
		return err
	}
	zr, err := zip.NewReader(remote, remote.size)
	if err != nil {
		return err
	}
	byName := map[string]*zip.File{}
	for _, f := range zr.File {
		byName[f.Name] = f
	}
	for _, n := range missing {
		f, ok := byName["templates/"+n]
		if !ok {
			return fmt.Errorf("templates/%s is not in %s", n, url)
		}
		if err := extract(f, filepath.Join(dest, n), 0o755); err != nil {
			return err
		}
	}
	logf("Templates ready in %s (downloaded %d MB of %d MB)", dest, remote.fetched/1_000_000, remote.size/1_000_000)
	return nil
}

// remoteFile is an io.ReaderAt over HTTP range requests, cached in large
// blocks so the zip reader's many small reads don't each cost a request.
type remoteFile struct {
	url     string
	size    int64
	fetched int64
	blocks  map[int64][]byte
	order   []int64
}

const blockSize = 4 << 20
const maxBlocks = 8

func openRemote(url string) (*remoteFile, error) {
	resp, err := client.Head(url)
	if err != nil {
		return nil, err
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || resp.ContentLength <= 0 {
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	// Remember the final URL after GitHub's redirect.
	return &remoteFile{url: resp.Request.URL.String(), size: resp.ContentLength, blocks: map[int64][]byte{}}, nil
}

func (r *remoteFile) block(i int64) ([]byte, error) {
	if b, ok := r.blocks[i]; ok {
		return b, nil
	}
	start := i * blockSize
	end := min64(start+blockSize, r.size) - 1
	req, _ := http.NewRequest(http.MethodGet, r.url, nil)
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", start, end))
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusPartialContent {
		return nil, errors.New("the server doesn't support range requests: " + resp.Status)
	}
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	r.fetched += int64(len(b))
	r.blocks[i] = b
	r.order = append(r.order, i)
	if len(r.order) > maxBlocks {
		delete(r.blocks, r.order[0])
		r.order = r.order[1:]
	}
	return b, nil
}

func (r *remoteFile) ReadAt(p []byte, off int64) (int, error) {
	n := 0
	for n < len(p) {
		pos := off + int64(n)
		if pos >= r.size {
			return n, io.EOF
		}
		b, err := r.block(pos / blockSize)
		if err != nil {
			return n, err
		}
		n += copy(p[n:], b[pos%blockSize:])
	}
	return n, nil
}

func min64(a, b int64) int64 {
	if a < b {
		return a
	}
	return b
}
