package edu.nyu.cs.examples;

import java.io.DataInput;
import java.io.DataOutput;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.Random;

import org.apache.hadoop.conf.Configured;
import org.apache.hadoop.fs.FileSystem;
import org.apache.hadoop.fs.Path;
import org.apache.hadoop.io.DoubleWritable;
import org.apache.hadoop.io.IntWritable;
import org.apache.hadoop.io.LongWritable;
import org.apache.hadoop.io.SequenceFile;
import org.apache.hadoop.io.Writable;
import org.apache.hadoop.mapred.FileInputFormat;
import org.apache.hadoop.mapred.FileOutputFormat;
import org.apache.hadoop.mapred.JobClient;
import org.apache.hadoop.mapred.JobConf;
import org.apache.hadoop.mapred.OutputCollector;
import org.apache.hadoop.mapred.Partitioner;
import org.apache.hadoop.mapred.Reporter;
import org.apache.hadoop.mapred.join.CompositeInputFormat;
import org.apache.hadoop.mapred.join.TupleWritable;
import org.apache.hadoop.util.Tool;
import org.apache.hadoop.util.ToolRunner;

public class Pagerank {
  public static final int NUMSHARDS = 32;
  public static final int NUMPAGES = 10 * 1000 * 1000;
  public static final double PROPAGATION_FACTOR = 0.8;

  public static class PRGraphWritable implements Writable {
    public int numTargets;
    public int targetSites[];
    public int targetPages[];

    @Override
    public void readFields(DataInput in) throws IOException {
      numTargets = in.readInt();
      targetPages = new int[numTargets];
      targetSites = new int[numTargets];
      for (int i = 0; i < numTargets; ++i) {
        targetSites[i] = in.readInt();
        targetPages[i] = in.readInt();
      }
    }

    @Override
    public void write(DataOutput out) throws IOException {
      out.writeInt(numTargets);
      for (int i = 0; i < numTargets; ++i) {
        out.writeInt(targetSites[i]);
        out.writeInt(targetPages[i]);
      }
    }

  }

  public static class PRPartition implements
      Partitioner<LongWritable, Writable> {
    @Override
    public int getPartition(LongWritable key, Writable value, int numPartitions) {
      return (int) ((key.get() >>> 32) % numPartitions);
    }

    @Override
    public void configure(JobConf job) {
      // TODO Auto-generated method stub

    }

  }

  public static class PRMap
      implements
      org.apache.hadoop.mapred.Mapper<LongWritable, TupleWritable, LongWritable, DoubleWritable> {

    @Override
    public void map(LongWritable key, TupleWritable value,
        OutputCollector<LongWritable, DoubleWritable> output, Reporter reporter)
        throws IOException {
      PRGraphWritable g = (PRGraphWritable) value.get(0);
      double v = ((DoubleWritable) value.get(1)).get();
      for (int i = 0; i < g.numTargets; ++i) {
        output.collect(new LongWritable(g.targetSites[i] << 32
            | g.targetPages[i]), new DoubleWritable(PROPAGATION_FACTOR * v
            / g.numTargets));
      }
    }

    @Override
    public void configure(JobConf job) {
    }

    @Override
    public void close() throws IOException {
    }

  }

  public static class PRReduce
      implements
      org.apache.hadoop.mapred.Reducer<LongWritable, DoubleWritable, LongWritable, DoubleWritable> {

    @Override
    public void reduce(LongWritable key, Iterator<DoubleWritable> values,
        OutputCollector<LongWritable, DoubleWritable> output, Reporter reporter)
        throws IOException {
      double sum = 0;
      while (values.hasNext()) {
        sum += values.next().get();
      }
      output.collect(key, new DoubleWritable(sum));
    }

    @Override
    public void configure(JobConf job) {
      // TODO Auto-generated method stub

    }

    @Override
    public void close() throws IOException {
      // TODO Auto-generated method stub

    }
  }

  public static void buildGraph(JobConf job) throws IOException {
    FileSystem fs = FileSystem.get(job);
    fs.delete(new Path("/pr/output/"), true);

    SequenceFile.Writer graphWriters[] = new SequenceFile.Writer[NUMSHARDS];
    SequenceFile.Writer rankWriters[] = new SequenceFile.Writer[NUMSHARDS];
    for (int i = 0; i < NUMSHARDS; ++i) {
      System.err.printf("Creating writers... %d\n", i);
      graphWriters[i] = SequenceFile.createWriter(fs, job, new Path(String
          .format("/pr/graph/test-%05d-of-%05d.rec", i, NUMSHARDS)),
          LongWritable.class, PRGraphWritable.class,
          SequenceFile.CompressionType.BLOCK);

      rankWriters[i] = new SequenceFile.Writer(fs, job, new Path(String.format(
          "/pr/rank/rank-%05d-of-%05d.rec", i, NUMSHARDS)), LongWritable.class,
          DoubleWritable.class);
    }

    ArrayList<Integer> siteSizes = new ArrayList<Integer>();
    int totalSize = 0;
    Random rand = new Random();
    while (totalSize < NUMPAGES) {
      int s = 50 + rand.nextInt(10000);
      siteSizes.add(s);
      totalSize += s;
    }

    System.err.printf("Writing graph: %d sites, %d pages.\n", siteSizes.size(),
        totalSize);
    for (int i = 0; i < siteSizes.size(); ++i) {
      if (i % 10 == 0) {
        System.err.println("... " + i);
      }

      for (int j = 0; j < siteSizes.get(i); ++j) {
        PRGraphWritable w = new PRGraphWritable();
        w.targetPages = new int[10];
        w.targetSites = new int[10];
        w.numTargets = 10;

        for (int k = 0; k < 10; ++k) {
          int targetSite = i;
          if (rand.nextInt(100) > 85) {
            targetSite = rand.nextInt(siteSizes.size());
          }

          w.targetSites[k] = targetSite;
          w.targetPages[k] = rand.nextInt(siteSizes.get(targetSite));
        }

        graphWriters[i % NUMSHARDS].append(new LongWritable(i << 32 | j), w);
        rankWriters[i % NUMSHARDS].append(new LongWritable(i << 32 | j),
            new DoubleWritable(PROPAGATION_FACTOR / totalSize));
      }

    }

    for (int i = 0; i < NUMSHARDS; ++i) {
      graphWriters[i].close();
    }
  }

  public static class PRTool extends Configured implements Tool {
    @Override
    public int run(String[] args) throws Exception {
      JobConf job = new JobConf(Pagerank.class);

      job.setJarByClass(Pagerank.class);
      job.setMapperClass(PRMap.class);
      job.setReducerClass(PRReduce.class);
      job.setCombinerClass(PRReduce.class);
      job.setInputFormat(CompositeInputFormat.class);
      job.setOutputFormat(org.apache.hadoop.mapred.SequenceFileOutputFormat.class);
      job.setOutputKeyClass(LongWritable.class);
      job.setOutputValueClass(DoubleWritable.class);
      // FileInputFormat.setInputPaths(job, new Path(/pr/));
      FileOutputFormat.setOutputPath(job, new Path("/pr/rank_out/"));

      job.set("mapred.join.expr", CompositeInputFormat.compose("outer",
          org.apache.hadoop.mapred.SequenceFileInputFormat.class, "/pr/graph/*",
          "/pr/rank/*"));      

      // buildGraph(job);

      JobClient.runJob(job);
      return 0;
    }
  }

  public static void main(String[] args) throws Exception {
    ToolRunner.run(new PRTool(), null);
    ;
  }
}