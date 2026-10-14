package zombie;
public class ZomboidFileSystem { public static ZomboidFileSystem instance = new ZomboidFileSystem();
 public String getCacheDir(){ return System.getProperty("fake.cache"); } }
