package com.drengrcode.realreset;

import java.io.File;
import java.lang.reflect.Method;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.Deque;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import se.krka.kahlua.integration.annotations.LuaMethod;

/**
 * RealReset! - server-side chunk reset for Project Zomboid (B42), loaded via ZombieBuddy.
 *
 * What it does: moves a chunk's save file (map/<wx>/<wy>.bin) into a trash folder so the
 * chunk regenerates from the base map the next time it loads.
 *
 * What it will NEVER do:
 *   - permanently delete a chunk file (a failed move is logged and left alone)
 *   - touch the network, run programs, or read anything outside the world save folder
 *   - move a chunk while a player is within the safety radius, or while the server says
 *     the chunk is loaded in memory
 *
 * It does NOT check who is calling. The admin check lives in the Lua side
 * (RealReset_Server.lua). Because these functions are global Lua functions, any other
 * server-side mod could call them - so this class also enforces a hard rate ceiling.
 *
 * Everything touching game classes is reflective: it compiles without the game jars, and
 * selfTest() reports which hooks still work after a game update. If an essential hook is
 * missing, the tool refuses to move anything.
 */
public final class RealReset {

    private RealReset() {}

    public static final String VERSION = "0.4.0";

    // ---- result codes (returned to Lua) -------------------------------------------
    public static final int MOVED        =  1; // (preview: would be moved)
    public static final int NO_FILE      =  0; // nothing on disk: never saved / already clean
    public static final int SKIP_PLAYER  = -1; // a player is within the safety radius
    public static final int SKIP_LOADED  = -2; // server says the chunk is loaded
    public static final int FAILED       = -3; // the file move failed (file left in place)
    public static final int REFUSED      = -4; // tool not ready / rate ceiling / cannot read players

    // ---- limits (override with -Drealreset.xxx=N in the JVM args if you must) ------
    private static final int  RADIUS_FLOOR   = 4;   // Lua may ask for more, never less
    private static final int  RADIUS_DEFAULT = 8;
    private static final int  MAX_MOVES      = intProp("realreset.maxMoves", 3000);  // per window
    private static final long WINDOW_MS      = 10L * 60L * 1000L;
    private static final int  TRASH_DAYS     = intProp("realreset.trashDays", 7);
    private static final int  TRASH_MAX      = intProp("realreset.trashMax", 20000);
    private static final String TRASH_DIR    = "_realreset_trash";
    private static final Pattern RUN_NAME    = Pattern.compile("^run_(\\d{10,16})__([A-Za-z0-9_-]{0,40})$");
    private static final Pattern RUN_FILE    = Pattern.compile("^(-?\\d+)_(-?\\d+)(_\\d+)?\\.bin$");
    private static final Pattern TRASH_NAME  = Pattern.compile("^(-?\\d+)_(-?\\d+)_(\\d+)\\.bin$");

    // ---- state ----------------------------------------------------------------------
    private static volatile boolean ready = false;
    private static volatile boolean loadedCheckOk = false;
    private static volatile boolean selfTestRan = false;
    private static volatile String currentRun = null;   // folder name of the batch being written
    private static volatile int currentRunMoves = 0;
    private static final Deque<Long> recentMoves = new ArrayDeque<Long>();

    private static void log(String s) { System.out.println("[RealReset] " + s); }

    private static int intProp(String key, int def) {
        try { return Integer.parseInt(System.getProperty(key, String.valueOf(def))); }
        catch (Throwable t) { return def; }
    }

    // ================================================================================
    //  Game access (all reflective)
    // ================================================================================

    private static String getCacheDir() {
        try {
            Class<?> zfs = Class.forName("zombie.ZomboidFileSystem");
            Object inst = zfs.getField("instance").get(null);
            Object r = zfs.getMethod("getCacheDir").invoke(inst);
            return r != null ? r.toString() : null;
        } catch (Throwable t) { log("getCacheDir failed: " + t); return null; }
    }

    private static String staticString(String cls, String field) {
        try {
            Object r = Class.forName(cls).getField(field).get(null);
            return (r != null && !r.toString().isEmpty()) ? r.toString() : null;
        } catch (Throwable t) { return null; }
    }

    /** World folder name. Override: -Drealreset.world=<name>. Otherwise try known game fields. */
    private static String serverName() {
        String o = System.getProperty("realreset.world");
        if (o != null && !o.isEmpty()) return o;
        String[][] candidates = {
            {"zombie.network.GameServer", "ServerName"},
            {"zombie.network.GameServer", "serverName"},
            {"zombie.core.Core", "GameSaveWorld"},
        };
        for (String[] c : candidates) {
            String v = staticString(c[0], c[1]);
            if (v != null) return v;
        }
        return null;
    }

    private static boolean isInside(File base, File child) {
        try {
            String b = base.getCanonicalPath() + File.separator;
            return child.getCanonicalPath().startsWith(b);
        } catch (Throwable t) { return false; }
    }

    private static volatile File cachedSave = null;

    /** The world save folder (resolved once per self-test, then cached). */
    private static File saveDir() {
        File c = cachedSave;
        if (c != null && c.isDirectory()) return c;
        c = resolveSaveDir();
        cachedSave = c;
        return c;
    }

    /** By server name; if that fails, only if there is exactly one folder. */
    private static File resolveSaveDir() {
        String cache = getCacheDir();
        if (cache == null) return null;
        File base = new File(new File(cache, "Saves"), "Multiplayer");
        String name = serverName();
        if (name != null && !name.isEmpty()) {
            File f = new File(base, name);
            if (f.isDirectory() && isInside(base, f)) return f;
            log("save folder for server name '" + name + "' not found at " + f);
        }
        File[] subs = base.listFiles(File::isDirectory);
        if (subs != null && subs.length == 1) {
            log("server name unavailable; using the only save folder: " + subs[0].getName());
            return subs[0];
        }
        log("REFUSING: cannot tell which world save to use ("
                + (subs == null ? 0 : subs.length) + " folders under " + base + ")");
        return null;
    }

    private static File chunkFile(File save, int wx, int wy) {
        return new File(new File(new File(save, "map"), String.valueOf(wx)), wy + ".bin");
    }

    /** Chebyshev distance in chunks to the nearest online player. MAX_VALUE = nobody online. -1 = unreadable. */
    private static double nearestPlayerChunks(int wx, int wy, int cs) {
        try {
            Object list = Class.forName("zombie.network.GameServer").getMethod("getPlayers").invoke(null);
            if (!(list instanceof List)) return -1;
            double best = Double.MAX_VALUE;
            for (Object p : (List<?>) list) {
                if (p == null) continue;
                float px = ((Number) p.getClass().getMethod("getX").invoke(p)).floatValue();
                float py = ((Number) p.getClass().getMethod("getY").invoke(p)).floatValue();
                int pwx = (int) Math.floor(px / cs);
                int pwy = (int) Math.floor(py / cs);
                double d = Math.max(Math.abs(pwx - wx), Math.abs(pwy - wy));
                if (d < best) best = d;
            }
            return best;
        } catch (Throwable t) { log("nearestPlayerChunks failed: " + t); return -1; }
    }

    /** 1 = loaded in server memory, 0 = not loaded, -1 = could not tell. */
    private static int loadedState(int wx, int wy) {
        try {
            Class<?> sm = Class.forName("zombie.network.ServerMap");
            Object inst = sm.getField("instance").get(null);
            if (inst == null) return -1;
            Method m = sm.getMethod("getChunk", int.class, int.class);
            return m.invoke(inst, wx, wy) != null ? 1 : 0;
        } catch (Throwable t) { return -1; }
    }

    // ================================================================================
    //  Self-test
    // ================================================================================

    @LuaMethod(name = "RealReset_selfTest", global = true)
    public static String selfTest() {
        selfTestRan = true;
        cachedSave = null; // re-resolve (and re-log) once per self-test
        StringBuilder sb = new StringBuilder("RealReset " + VERSION + " | ");
        String cache = getCacheDir();
        sb.append("cacheDir=").append(cache != null ? "OK" : "FAIL");
        File save = saveDir();
        sb.append(" saveDir=").append(save != null ? "OK(" + save.getName() + ")" : "FAIL");
        boolean players = nearestPlayerChunks(0, 0, 8) != -1;
        sb.append(" players=").append(players ? "OK" : "FAIL");
        loadedCheckOk = loadedState(0, 0) != -1;
        sb.append(" loadedCheck=").append(loadedCheckOk ? "OK" : "UNAVAILABLE(radius-only)");
        ready = cache != null && save != null && players;
        sb.append(ready ? " | READY" : " | NOT READY - refusing to move chunks");
        int pruned = prune();
        if (pruned > 0) sb.append(" | trash pruned=").append(pruned);
        String out = sb.toString();
        log(out);
        return out;
    }

    @LuaMethod(name = "RealReset_isReady", global = true)
    public static boolean isReady() {
        if (!selfTestRan) selfTest();
        return ready;
    }

    @LuaMethod(name = "RealReset_ping", global = true)
    public static String ping() { return "RealReset " + VERSION + " (Java side loaded)"; }

    // ================================================================================
    //  Chunk evaluate / preview / move
    // ================================================================================

    private static synchronized boolean ceilingReached() {
        long now = System.currentTimeMillis();
        while (!recentMoves.isEmpty() && now - recentMoves.peekFirst() > WINDOW_MS) recentMoves.pollFirst();
        return recentMoves.size() >= MAX_MOVES;
    }

    private static synchronized void recordMove() { recentMoves.addLast(System.currentTimeMillis()); }

    /** "used|max|secondsUntilOneFrees" for the move limit. Lets the Lua side show it and wait. */
    @LuaMethod(name = "RealReset_ceilingInfo", global = true)
    public static synchronized String ceilingInfo() {
        long now = System.currentTimeMillis();
        while (!recentMoves.isEmpty() && now - recentMoves.peekFirst() > WINDOW_MS) recentMoves.pollFirst();
        long wait = recentMoves.isEmpty() ? 0 : Math.max(0L, (recentMoves.peekFirst() + WINDOW_MS - now) / 1000L);
        return recentMoves.size() + "|" + MAX_MOVES + "|" + wait;
    }

    private static int evaluate(int wx, int wy, int cs, int radius, boolean doMove) {
        if (!isReady()) return REFUSED;
        if (cs <= 0) cs = 8;
        if (radius < RADIUS_FLOOR) radius = RADIUS_DEFAULT;

        double d = nearestPlayerChunks(wx, wy, cs);
        if (d < 0) return REFUSED;
        if (d <= radius) return SKIP_PLAYER;

        int ls = loadedState(wx, wy);
        if (ls == 1) return SKIP_LOADED;
        if (ls == -1 && loadedCheckOk) return SKIP_LOADED; // check worked in self-test but not now: fail safe

        File save = saveDir();
        if (save == null) return REFUSED;
        File f = chunkFile(save, wx, wy);
        if (!f.exists()) return NO_FILE;
        if (!doMove) return MOVED;

        if (ceilingReached()) { log("REFUSED: rate ceiling (" + MAX_MOVES + " moves / 10 min) reached"); return REFUSED; }
        try {
            if (currentRun == null) beginRunInternal("adhoc");
            File runFolder = new File(new File(save, TRASH_DIR), currentRun == null ? "" : currentRun);
            if (currentRun == null || !runFolder.isDirectory()) { log("FAILED: no batch folder for trash"); return FAILED; }
            File dest = new File(runFolder, wx + "_" + wy + ".bin");
            if (dest.exists()) dest = new File(runFolder, wx + "_" + wy + "_" + System.currentTimeMillis() + ".bin");
            if (f.renameTo(dest)) {
                recordMove();
                currentRunMoves++;
                log("MOVED chunk " + wx + "," + wy + " -> " + TRASH_DIR + "/" + runFolder.getName() + "/" + dest.getName());
                return MOVED;
            }
            log("FAILED to move chunk " + wx + "," + wy + " (permissions, or file in use). Left in place.");
            return FAILED;
        } catch (Throwable t) {
            log("FAILED to move chunk " + wx + "," + wy + ": " + t + " (left in place)");
            return FAILED;
        }
    }

    /** Dry run: what would happen to this chunk. Never changes anything. */
    @LuaMethod(name = "RealReset_previewChunk", global = true)
    public static int previewChunk(int wx, int wy, int chunkSize, int radius) {
        return evaluate(wx, wy, chunkSize, radius, false);
    }

    /** Move the chunk file to trash if every safety check passes. Returns a result code. */
    @LuaMethod(name = "RealReset_moveChunk", global = true)
    public static int moveChunk(int wx, int wy, int chunkSize, int radius) {
        return evaluate(wx, wy, chunkSize, radius, true);
    }

    /** Human-readable diagnostics for one chunk (also logged). */
    @LuaMethod(name = "RealReset_chunkReport", global = true)
    public static String chunkReport(int wx, int wy, int chunkSize) {
        int cs = chunkSize <= 0 ? 8 : chunkSize;
        File save = saveDir();
        String file = save == null ? "no save dir" : chunkFile(save, wx, wy).getAbsolutePath()
                + " exists=" + chunkFile(save, wx, wy).exists();
        double d = nearestPlayerChunks(wx, wy, cs);
        String out = "chunk " + wx + "," + wy + " | " + file
                + " | nearestPlayer=" + (d == Double.MAX_VALUE ? "none" : String.valueOf(d))
                + " | loaded=" + loadedState(wx, wy);
        log(out);
        return out;
    }

    // ================================================================================
    //  Batches ("runs"): every RESET writes into its own folder inside the trash,
    //  so a whole reset can be listed and restored together.
    // ================================================================================

    private static String sanitizeLabel(String label) {
        String l = label == null ? "" : label.replaceAll("[^A-Za-z0-9_-]", "_");
        return l.length() > 40 ? l.substring(0, 40) : l;
    }

    private static String beginRunInternal(String label) {
        File save = saveDir();
        if (save == null) { currentRun = null; return ""; }
        String name = "run_" + System.currentTimeMillis() + "__" + sanitizeLabel(label);
        File dir = new File(new File(save, TRASH_DIR), name);
        if (!dir.mkdirs() && !dir.isDirectory()) { log("could not create batch folder " + dir); currentRun = null; return ""; }
        currentRun = name;
        currentRunMoves = 0;
        log("batch started: " + name);
        return name;
    }

    /** Start a new batch folder in the trash. Returns its id, or "" if it could not be created. */
    @LuaMethod(name = "RealReset_beginRun", global = true)
    public static String beginRun(String label) {
        if (!isReady()) return "";
        return beginRunInternal(label);
    }

    /** Finish the current batch. Returns how many chunks it holds. Empty batch folders are removed. */
    @LuaMethod(name = "RealReset_endRun", global = true)
    public static int endRun() {
        String r = currentRun;
        int n = currentRunMoves;
        currentRun = null;
        currentRunMoves = 0;
        try {
            File save = saveDir();
            if (r != null && save != null && n == 0) new File(new File(save, TRASH_DIR), r).delete(); // only works if empty
        } catch (Throwable t) { /* ignore */ }
        if (r != null) log("batch finished: " + r + " (" + n + " chunk(s))");
        return n;
    }

    private static File runDir(String runId) {
        if (runId == null || !RUN_NAME.matcher(runId).matches()) return null; // also blocks path tricks
        File save = saveDir();
        if (save == null) return null;
        File d = new File(new File(save, TRASH_DIR), runId);
        return d.isDirectory() ? d : null;
    }

    private static int countBins(File dir) {
        File[] fs = dir.listFiles();
        int n = 0;
        if (fs != null) for (File f : fs) if (f.isFile() && RUN_FILE.matcher(f.getName()).matches()) n++;
        return n;
    }

    /** Batches still holding chunks, newest first: "id|description|count;id|description|count;..." (max 30). */
    @LuaMethod(name = "RealReset_listRuns", global = true)
    public static String listRuns() {
        try {
            File save = saveDir();
            if (save == null) return "";
            File[] dirs = new File(save, TRASH_DIR).listFiles();
            if (dirs == null) return "";
            List<File> runs = new ArrayList<File>();
            for (File d : dirs) if (d.isDirectory() && RUN_NAME.matcher(d.getName()).matches()) runs.add(d);
            Collections.sort(runs, new Comparator<File>() {
                public int compare(File a, File b) { return b.getName().compareTo(a.getName()); }
            });
            java.text.SimpleDateFormat fmt = new java.text.SimpleDateFormat("dd/MM HH:mm");
            StringBuilder sb = new StringBuilder();
            int shown = 0;
            for (File d : runs) {
                int n = countBins(d);
                if (n == 0) continue;
                Matcher m = RUN_NAME.matcher(d.getName());
                m.matches();
                String when = fmt.format(new java.util.Date(Long.parseLong(m.group(1))));
                String label = m.group(2).replace('_', ' ').trim();
                sb.append(d.getName()).append('|').append(when).append(' ').append(label)
                  .append(" (").append(n).append(")").append(';');
                if (++shown >= 30) break;
            }
            return sb.toString();
        } catch (Throwable t) { log("listRuns failed: " + t); return ""; }
    }

    /** Chunks still in a batch: "wx,wy;wx,wy;...". */
    @LuaMethod(name = "RealReset_runChunks", global = true)
    public static String runChunks(String runId) {
        File d = runDir(runId);
        if (d == null) return "";
        File[] fs = d.listFiles();
        if (fs == null) return "";
        StringBuilder sb = new StringBuilder();
        for (File f : fs) {
            Matcher m = RUN_FILE.matcher(f.getName());
            if (f.isFile() && m.matches() && m.group(3) == null) sb.append(m.group(1)).append(',').append(m.group(2)).append(';');
        }
        return sb.toString();
    }

    /** Newest batch that still holds this chunk, or "". */
    @LuaMethod(name = "RealReset_findLatestRun", global = true)
    public static String findLatestRun(int wx, int wy) {
        try {
            File save = saveDir();
            if (save == null) return "";
            File[] dirs = new File(save, TRASH_DIR).listFiles();
            if (dirs == null) return "";
            String best = "";
            for (File d : dirs) {
                if (!d.isDirectory() || !RUN_NAME.matcher(d.getName()).matches()) continue;
                if (new File(d, wx + "_" + wy + ".bin").isFile() && d.getName().compareTo(best) > 0) best = d.getName();
            }
            return best;
        } catch (Throwable t) { return ""; }
    }

    /**
     * Put one chunk back from a batch. Same safety checks as a reset (no player near, not loaded).
     * If the game already regenerated a file for this chunk, that file is moved aside into the
     * batch's "replaced" folder, never overwritten. Codes: MOVED(1)=restored / would restore,
     * NO_FILE(0)=not in this batch, SKIP_PLAYER, SKIP_LOADED, FAILED, REFUSED.
     */
    @LuaMethod(name = "RealReset_restoreChunk", global = true)
    public static int restoreChunk(String runId, int wx, int wy, int chunkSize, int radius, boolean doMove) {
        if (!isReady()) return REFUSED;
        int cs = chunkSize <= 0 ? 8 : chunkSize;
        if (radius < RADIUS_FLOOR) radius = RADIUS_DEFAULT;
        File rd = runDir(runId);
        if (rd == null) return REFUSED;
        File src = new File(rd, wx + "_" + wy + ".bin");
        if (!src.isFile()) return NO_FILE;

        double d = nearestPlayerChunks(wx, wy, cs);
        if (d < 0) return REFUSED;
        if (d <= radius) return SKIP_PLAYER;
        int ls = loadedState(wx, wy);
        if (ls == 1) return SKIP_LOADED;
        if (ls == -1 && loadedCheckOk) return SKIP_LOADED;

        File save = saveDir();
        if (save == null) return REFUSED;
        if (!doMove) return MOVED;
        if (ceilingReached()) { log("REFUSED: rate ceiling reached"); return REFUSED; }

        File dest = chunkFile(save, wx, wy);
        File aside = null;
        try {
            if (dest.exists()) {
                File rep = new File(rd, "replaced");
                rep.mkdirs();
                aside = new File(rep, wx + "_" + wy + "_" + System.currentTimeMillis() + ".bin");
                if (!dest.renameTo(aside)) { log("FAILED restore " + wx + "," + wy + ": could not move the current file aside"); return FAILED; }
            }
            File parent = dest.getParentFile();
            if (parent != null) parent.mkdirs();
            if (src.renameTo(dest)) {
                recordMove();
                log("RESTORED chunk " + wx + "," + wy + " from " + rd.getName() + (aside != null ? " (current file kept in replaced/)" : ""));
                return MOVED;
            }
            if (aside != null) aside.renameTo(dest); // put the current file back
            log("FAILED restore " + wx + "," + wy + " (file left in trash)");
            return FAILED;
        } catch (Throwable t) {
            if (aside != null && !dest.exists()) aside.renameTo(dest);
            log("FAILED restore " + wx + "," + wy + ": " + t);
            return FAILED;
        }
    }

    // ================================================================================
    //  Trash housekeeping (the only place this class deletes anything, and only
    //  files it created itself, matching <wx>_<wy>_<millis>.bin inside the trash folder)
    // ================================================================================

    @LuaMethod(name = "RealReset_pruneTrash", global = true)
    public static int pruneTrash() { return prune(); }

    /** Delete one batch folder, but only if it holds nothing except our own file names. */
    private static int deleteRunFolder(File dir) {
        int n = 0;
        File[] fs = dir.listFiles();
        if (fs == null) return 0;
        for (File f : fs) {
            if (f.isFile() && RUN_FILE.matcher(f.getName()).matches()) { if (f.delete()) n++; }
            else if (f.isDirectory() && f.getName().equals("replaced")) {
                File[] rs = f.listFiles();
                if (rs != null) for (File r : rs) if (r.isFile() && RUN_FILE.matcher(r.getName()).matches() && r.delete()) n++;
                f.delete(); // only succeeds if empty
            }
        }
        dir.delete(); // only succeeds if empty
        return n;
    }

    private static int pruneRuns(File trash) {
        File[] dirs = trash.listFiles();
        if (dirs == null) return 0;
        final long now = System.currentTimeMillis();
        final long maxAge = TRASH_DAYS * 24L * 3600L * 1000L;
        List<File> keep = new ArrayList<File>();
        int deleted = 0, total = 0;
        for (File d : dirs) {
            Matcher m = RUN_NAME.matcher(d.getName());
            if (!d.isDirectory() || !m.matches()) continue;
            if (TRASH_DAYS >= 0 && now - Long.parseLong(m.group(1)) > maxAge) deleted += deleteRunFolder(d);
            else { keep.add(d); total += countBins(d); }
        }
        if (total > TRASH_MAX) {
            Collections.sort(keep, new Comparator<File>() {
                public int compare(File a, File b) { return a.getName().compareTo(b.getName()); }
            });
            for (File d : keep) {
                if (total <= TRASH_MAX) break;
                int c = countBins(d);
                deleted += deleteRunFolder(d);
                total -= c;
            }
        }
        return deleted;
    }

    private static int prune() {
        try {
            File save = saveDir();
            if (save == null) return 0;
            File trash = new File(save, TRASH_DIR);
            File[] files = trash.listFiles();
            if (files == null) return 0;
            int runsDeleted = pruneRuns(trash);
            final long now = System.currentTimeMillis();
            final long maxAge = TRASH_DAYS * 24L * 3600L * 1000L;
            List<File> mine = new ArrayList<File>();
            int deleted = 0;
            for (File f : files) {
                Matcher m = TRASH_NAME.matcher(f.getName());
                if (!f.isFile() || !m.matches()) continue;   // never touch anything else
                long moved = Long.parseLong(m.group(3));
                if (TRASH_DAYS >= 0 && now - moved > maxAge) { if (f.delete()) deleted++; }
                else mine.add(f);
            }
            if (mine.size() > TRASH_MAX) {
                Collections.sort(mine, new Comparator<File>() {
                    public int compare(File a, File b) { return Long.compare(stamp(a), stamp(b)); }
                });
                for (int i = 0; i < mine.size() - TRASH_MAX; i++) if (mine.get(i).delete()) deleted++;
            }
            deleted += runsDeleted;
            if (deleted > 0) log("trash pruned: " + deleted + " old file(s)");
            return deleted;
        } catch (Throwable t) { log("prune failed: " + t); return 0; }
    }

    private static long stamp(File f) {
        Matcher m = TRASH_NAME.matcher(f.getName());
        return m.matches() ? Long.parseLong(m.group(3)) : 0L;
    }
}
