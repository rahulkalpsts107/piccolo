#include "examples/examples.h"
#include "webgraph.h"

#include <algorithm>
#include <libgen.h>

using namespace dsm;
using namespace std;

static float TOTALRANK = 0;
static int NUM_WORKERS = 2;

static const float kPropagationFactor = 0.8;
static const int kBlocksize = 1000;
static const char kTestPrefix[] = "testdata/pr-graph.rec";

DEFINE_bool(memory_graph, false,
            "If true, the web graph will be generated on-demand.");

DEFINE_string(graph_prefix, kTestPrefix, "Path to web graph.");
DEFINE_int32(nodes, 10000, "");

DEFINE_string(convert_graph, "", "Path to WebGraph .graph.gz database to convert");

static float powerlaw_random(float dmin, float dmax, float n) {
  float r = (float)random() / RAND_MAX;
  return pow((pow(dmax, n) - pow(dmin, n)) * pow(r, 3) + pow(dmin, n), 1.0/n);
}

static float random_restart_seed() {
  return (1-kPropagationFactor)*(TOTALRANK/FLAGS_nodes);
}

// I'd like to use a pair here, but for some reason they fail to count
// as POD types according to C++.  Sigh.
struct PageId {
  int64_t site : 32;
  int64_t page : 32;
};

bool operator==(const PageId& a, const PageId& b) {
  return a.site == b.site && a.page == b.page;
}

namespace std { namespace tr1 {
template <>
struct hash<PageId> {
  size_t operator()(const PageId& p) const {
    return SuperFastHash((const char*)&p, sizeof p);
  }
};
} }

struct SiteSharding : public Sharder<PageId> {
  int operator()(const PageId& p, int nshards) {
    return p.site % nshards;
  }
};

struct PageIdBlockInfo : public BlockInfo<PageId> {
  PageId start(const PageId& k, int block_size)  {
    PageId p = { k.site, k.page - (k.page % block_size) };
    return p;
  }

  int offset(const PageId& k, int block_size) {
    return k.page % block_size;
  }
};


static vector<int> InitSites() {
  vector<int> site_sizes;
  srand(0);
  for (int n = 0; n < FLAGS_nodes; ) {
    int c = powerlaw_random(1, min(50000,
                                   (int)(100000. * FLAGS_nodes / 100e6)), 0.001);
    site_sizes.push_back(c);
    n += c;
  }
  return site_sizes;
}
static vector<int> site_sizes = InitSites();

static void BuildGraph(int shard, int nshards, int nodes, int density) {
  char* d = strdup(FLAGS_graph_prefix.c_str());
  File::Mkdirs(dirname(d));

  string target = StringPrintf("%s-%05d-of-%05d-N%05d", FLAGS_graph_prefix.c_str(), shard, nshards, nodes);

  if (File::Exists(target)) {
    return;
  }

  srand(shard);
  Page n;
  RecordFile out(target, "w", RecordFile::LZO);
  // Only sites with site_id % nshards == shard are in this shard.
  for (int i = shard; i < site_sizes.size(); i += nshards) {
    for (int j = 0; j < site_sizes[i]; ++j) {
      n.Clear();
      n.set_site(i);
      n.set_id(j);
      for (int k = 0; k < density; k++) {
        int target_site = (random() % 10 != 0) ? i : (random() % site_sizes.size());
        n.add_target_site(target_site);
        n.add_target_id(random() % site_sizes[target_site]);
      }
      out.write(n);
    }
  }
}

static void WebGraphPageIds(WebGraph::Reader *wgr, vector<PageId> *out) {
  WebGraph::URLReader *r = wgr->newURLReader();
  struct PageId pid = {-1, -1};
  string prev, url;
  int prevHostLen = 0;
  int i = 0;

  out->reserve(wgr->nodes);

  while (r->readURL(&url)) {
    if (i++ % 100000 == 0)
      LOG(INFO) << "Reading URL " << i-1 << " of " << wgr->nodes;

    // Get host part
    int hostLen = url.find('/', 8);
    CHECK(hostLen != url.npos) << "Failed to split host in URL " << url;
    ++hostLen;

    if (prev.compare(0, prevHostLen, url, 0, hostLen) == 0) {
      // Same site
      ++pid.page;
    } else {
      // Different site
      ++pid.site;
      pid.page = 0;

      swap(prev, url);
      prevHostLen = hostLen;
    }

    out->push_back(pid);
  }

  delete r;

  LOG(INFO) << pid.site+1 << " total sites read";
}

static void ConvertGraph(string path, int nshards) {
  WebGraph::Reader r(path);
  vector<PageId> pageIds;
  WebGraphPageIds(&r, &pageIds);

  char* d = strdup(FLAGS_graph_prefix.c_str());
  File::Mkdirs(dirname(d));

  RecordFile *out[nshards];
  for (int i = 0; i < nshards; ++i) {
    string target = StringPrintf("%s-%05d-of-%05d-N%05d", FLAGS_graph_prefix.c_str(), i, nshards, r.nodes);
    out[i] = new RecordFile(target, "w", RecordFile::LZO);
  }

  // XXX Maybe we should take at most FLAGS_nodes nodes
  const WebGraph::Node *node;
  Page n;
  while ((node = r.readNode())) {
    if (node->node % 100000 == 0)
      LOG(INFO) << "Reading node " << node->node << " of " << r.nodes;
    PageId src = pageIds.at(node->node);
    n.Clear();
    n.set_site(src.site);
    n.set_id(src.page);
    for (unsigned int i = 0; i < node->links.size(); ++i) {
      PageId dest = pageIds.at(node->links[i]);
      n.add_target_site(dest.site);
      n.add_target_id(dest.page);
    }
    out[src.site % nshards]->write(n);
  }

  for (int i = 0; i < nshards; ++i)
    delete out[i];
}

// Generate a graph on-demand rather then reading from disk.
class InMemoryTable : public DiskTable<uint64_t, Page> {
public:
  struct Iterator : public TypedTableIterator<uint64_t, Page> {
    Iterator(int shard, int num_shards) : shard_(shard), site_(shard), site_pos_(0), num_shards_(num_shards) {
      srand(shard);
    }

    Page p_;
    uint64_t k_;


    const uint64_t& key() { k_ = 0; return k_; }
    Page& value() { return p_; }

    void Next() {
      if (site_pos_ >= site_sizes[site_]) {
        site_ += num_shards_;
        site_pos_ = 0;
      }

      p_.Clear();
      p_.set_site(site_);
      p_.set_id(site_pos_);

//      k_ = P(site_, site_pos_);

      for (int k = 0; k < 15; k++) {
        int target_site = (random() % 10 != 0) ? site_ : (random() % site_sizes.size());
        p_.add_target_site(target_site);
        p_.add_target_id(random() % site_sizes[target_site]);
      }

      ++site_pos_;
    }

    bool done() {
      return (site_ >= site_sizes.size());
    }
  private:
    int shard_;
    int site_;
    int site_pos_;
    int num_shards_;
  };

  InMemoryTable(int num_shards) : DiskTable<uint64_t, Page>("", 0), num_shards_(num_shards) {}
  Iterator *get_iterator(int shard, unsigned int fetch_num) { return new Iterator(shard, num_shards_); }

private:
  int num_shards_;
};

TypedGlobalTable<PageId, float>* curr_pr;
TypedGlobalTable<PageId, float>* next_pr;
DiskTable<uint64_t, Page> *pages;

int Pagerank(ConfigData& conf) {
  NUM_WORKERS = conf.num_workers();
  TOTALRANK = FLAGS_nodes;

  TableDescriptor* pr_desc = new TableDescriptor(0, FLAGS_shards);
  pr_desc->key_marshal = new Marshal<PageId>;
  pr_desc->value_marshal = new Marshal<float>;

  pr_desc->partition_factory = new SparseTable<PageId, float>::Factory;
  pr_desc->block_size = 1000;
  pr_desc->block_info = new PageIdBlockInfo;
  pr_desc->sharder = new SiteSharding;
  pr_desc->accum = new Accumulators<float>::Sum;

  CreateTable<PageId, float>(pr_desc);
  pr_desc->table_id = 1;
  CreateTable<PageId, float>(pr_desc);

  if (FLAGS_memory_graph) {
    pages = new InMemoryTable(FLAGS_shards);
    TableRegistry::Get()->tables().insert(make_pair(2, pages));
  } else {
    pages = CreateRecordTable<Page>(2, FLAGS_graph_prefix + "*", false);
  }

  StartWorker(conf);
  Master m(conf);
  if (FLAGS_build_graph) {
    PRunAll(pages, {
      for (int i = 0; i < FLAGS_shards; ++i) {
         BuildGraph(i, FLAGS_shards, FLAGS_nodes, 15);
      }
    });

    return 0;
  }

  if (!FLAGS_convert_graph.empty()) {
    ConvertGraph(FLAGS_convert_graph, FLAGS_shards);
    return 0;
  }

  m.restore();

  int &i = m.get_cp_var<int>("iteration", 0);
  PRunAll(curr_pr, {
        next_pr->resize((int)(2 * FLAGS_nodes));
        curr_pr->resize((int)(2 * FLAGS_nodes));
  });

  for (; i < FLAGS_iterations; ++i) {
    PMap({ n : pages },  {
        struct PageId p = { n.site(), n.id() };
        next_pr->update(p, random_restart_seed());

        float v = 0;
        if (curr_pr->contains(p)) {
          v = curr_pr->get_local(p);
        }

        float contribution = kPropagationFactor * v / n.target_site_size();
        for (int i = 0; i < n.target_site_size(); ++i) {
          PageId target = { n.target_site(i), n.target_id(i) };
          next_pr->update(target, contribution);
        }
    });

    // Move the values computed from the last iteration into the current table.
    swap(curr_pr, next_pr);
    next_pr->clear();

    PRunOne(curr_pr, {
            fprintf(stderr, "Iteration %d, PR:: ", get_arg<int>("iteration"));
            PageId pzero = { 0, 0 };
            fprintf(stderr, "%.2f\n", curr_pr->get(pzero));
    });
  }

  return 0;
}
REGISTER_RUNNER(Pagerank);