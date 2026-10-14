import com.drengrcode.realreset.RealReset;
import zombie.network.*;
import java.io.*; import java.nio.file.*;
public class RestoreTest {
 static int fails=0;
 static void eq(String n,Object got,Object want){ boolean ok=String.valueOf(got).equals(String.valueOf(want)); System.out.println((ok?"PASS ":"FAIL ")+n+" got="+got+" want="+want); if(!ok) fails++; }
 static byte[] rd(File f) throws Exception { return Files.readAllBytes(f.toPath()); }
 public static void main(String[] a) throws Exception {
  String home=System.getProperty("fake.cache");
  File save=new File(home,"Saves/Multiplayer/Broc"); File map=new File(save,"map/10");
  Files.write(new File(map,"20.bin").toPath(), "OLD20".getBytes());
  Files.write(new File(map,"21.bin").toPath(), "OLD21".getBytes());
  RealReset.selfTest();
  GameServer.players.add(new FakePlayer(10*8+1,60*8+1)); // far away
  String run = RealReset.beginRun("test_by_adm");
  System.out.println("run="+run);
  eq("run id shape", run.matches("run_\\d+__test_by_adm"), true);
  eq("move 20", RealReset.moveChunk(10,20,8,8), 1);
  eq("move 21", RealReset.moveChunk(10,21,8,8), 1);
  eq("endRun count", RealReset.endRun(), 2);
  eq("ceilingInfo", RealReset.ceilingInfo().matches("2\\|3000\\|\\d+"), true);
  eq("files in run", new File(save,"_realreset_trash/"+run).list().length, 2);
  String list = RealReset.listRuns(); System.out.println("list="+list);
  eq("list has count", list.contains("(2)") && list.startsWith(run+"|"), true);
  String chunks = RealReset.runChunks(run); System.out.println("chunks="+chunks);
  eq("runChunks", chunks.contains("10,20;") && chunks.contains("10,21;"), true);
  eq("findLatestRun", RealReset.findLatestRun(10,20), run);
  eq("findLatestRun none", RealReset.findLatestRun(99,99), "");
  // game regenerated chunk 20 meanwhile
  Files.write(new File(map,"20.bin").toPath(), "NEW20".getBytes());
  eq("preview restore", RealReset.restoreChunk(run,10,20,8,8,false), 1);
  eq("preview did not move", new File(save,"_realreset_trash/"+run+"/10_20.bin").exists(), true);
  GameServer.players.clear(); GameServer.players.add(new FakePlayer(10*8+1,23*8+1)); // near
  eq("restore blocked by player", RealReset.restoreChunk(run,10,20,8,8,true), -1);
  GameServer.players.clear(); GameServer.players.add(new FakePlayer(10*8+1,60*8+1));
  ServerMap.loaded.add("10,21");
  eq("restore blocked by loaded", RealReset.restoreChunk(run,10,21,8,8,true), -2);
  ServerMap.loaded.clear();
  eq("restore 20", RealReset.restoreChunk(run,10,20,8,8,true), 1);
  eq("content is OLD", new String(rd(new File(map,"20.bin"))), "OLD20");
  File rep=new File(save,"_realreset_trash/"+run+"/replaced");
  eq("regenerated kept aside", rep.list().length, 1);
  eq("aside content NEW", new String(rd(new File(rep,rep.list()[0]))), "NEW20");
  eq("restore again = no file", RealReset.restoreChunk(run,10,20,8,8,true), 0);
  eq("restore 21 (no existing)", RealReset.restoreChunk(run,10,21,8,8,true), 1);
  eq("content 21 OLD", new String(rd(new File(map,"21.bin"))), "OLD21");
  eq("bad run id", RealReset.restoreChunk("../../x",10,20,8,8,true), -4);
  eq("bad run id 2", RealReset.restoreChunk("run_1__x/../..",10,20,8,8,true), -4);
  eq("listRuns hides empty", RealReset.listRuns().contains(run), false);
  // prune old batch
  File old=new File(save,"_realreset_trash/run_1000000000000__old_by_x"); old.mkdirs();
  Files.write(new File(old,"5_5.bin").toPath(), "x".getBytes());
  Files.write(new File(old,"keep.txt").toPath(), "x".getBytes());
  int p=RealReset.pruneTrash();
  eq("pruned >=1", p>=1, true);
  eq("foreign file survives", new File(old,"keep.txt").exists(), true);
  eq("old bin gone", new File(old,"5_5.bin").exists(), false);
  System.out.println(fails==0?"ALL PASS":"FAILURES: "+fails);
 }
}
