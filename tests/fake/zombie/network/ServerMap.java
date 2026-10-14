package zombie.network;
public class ServerMap { public static ServerMap instance = new ServerMap(); public static java.util.Set<String> loaded = new java.util.HashSet<>();
 public Object getChunk(int x,int y){ return loaded.contains(x+","+y) ? new Object() : null; } }
