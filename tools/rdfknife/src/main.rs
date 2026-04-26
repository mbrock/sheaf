use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{self, BufReader, BufWriter, IsTerminal, Read, Write};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{Context, Result, bail};
use clap::{Parser, Subcommand, ValueEnum};
use flate2::Compression;
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use oxrdf::dataset::{CanonicalizationAlgorithm, CanonicalizationHashAlgorithm};
use oxrdf::{BlankNode, Dataset, GraphName, NamedNode, NamedOrBlankNode, Quad, Term, Triple};
use oxrdfio::{RdfFormat, RdfParser, RdfSerializer};
use sha2::{Digest, Sha256};

#[derive(Debug, Parser)]
#[command(version, about = "Small RDF utility knife for Sheaf datasets")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    /// Canonicalize an RDF dataset and write sorted N-Quads.
    Canonicalize(CanonicalizeArgs),

    /// Summarize blank-node shapes that make RDF diffs hard.
    AnalyzeBnodes(AnalyzeBnodesArgs),

    /// Diff two RDF datasets with RDF-aware blank-node normalization.
    Diff(DiffArgs),
}

#[derive(Debug, Parser)]
struct CanonicalizeArgs {
    /// Input RDF file. Use '-' or omit to read stdin.
    input: Option<PathBuf>,

    /// Output file. Use '-' or omit to write stdout.
    #[arg(short, long)]
    output: Option<PathBuf>,

    /// Input format. Defaults to the input extension, with .gz stripped first.
    #[arg(short, long)]
    format: Option<String>,

    /// Canonicalization algorithm.
    #[arg(long, value_enum, default_value_t = Algorithm::Rdfc10)]
    algorithm: Algorithm,

    /// Hash algorithm for RDFC-1.0.
    #[arg(long, value_enum, default_value_t = HashAlgorithm::Sha256)]
    hash: HashAlgorithm,

    /// Attempt to keep parsing even if the input is slightly invalid.
    #[arg(long)]
    lenient: bool,
}

#[derive(Debug, Parser)]
struct AnalyzeBnodesArgs {
    /// Input RDF file. Use '-' or omit to read stdin.
    input: Option<PathBuf>,

    /// Input format. Defaults to the input extension, with .gz stripped first.
    #[arg(short, long)]
    format: Option<String>,

    /// Number of graph rows and examples to print.
    #[arg(long, default_value_t = 30)]
    limit: usize,

    /// Attempt to keep parsing even if the input is slightly invalid.
    #[arg(long)]
    lenient: bool,
}

#[derive(Debug, Parser)]
struct DiffArgs {
    /// Left RDF dataset file.
    left: PathBuf,

    /// Right RDF dataset file.
    right: PathBuf,

    /// Left input format. Defaults to extension, with .gz stripped first.
    #[arg(long)]
    left_format: Option<String>,

    /// Right input format. Defaults to extension, with .gz stripped first.
    #[arg(long)]
    right_format: Option<String>,

    /// Output RDF 1.2/TriG diff path.
    #[arg(short, long)]
    output: PathBuf,

    /// Also write a human-readable diff. Use '-' for stdout.
    #[arg(long)]
    pretty: Option<PathBuf>,

    /// Color mode for --pretty.
    #[arg(long, value_enum, default_value_t = ColorMode::Auto)]
    color: ColorMode,

    /// Attempt to keep parsing even if an input is slightly invalid.
    #[arg(long)]
    lenient: bool,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum ColorMode {
    Auto,
    Always,
    Never,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum Algorithm {
    /// W3C RDF Dataset Canonicalization 1.0.
    Rdfc10,
    /// OxRDF's faster, version-dependent internal canonicalization.
    Unstable,
}

#[derive(Clone, Copy, Debug, ValueEnum)]
enum HashAlgorithm {
    Sha256,
    Sha384,
}

fn main() -> Result<()> {
    match Cli::parse().command {
        Command::Canonicalize(args) => canonicalize(args),
        Command::AnalyzeBnodes(args) => analyze_bnodes(args),
        Command::Diff(args) => diff(args),
    }
}

fn diff(args: DiffArgs) -> Result<()> {
    let total_start = Instant::now();
    eprintln!(
        "[{:>8}] normalizing left: {}",
        format_duration(total_start.elapsed()),
        args.left.display()
    );
    let left = normalize_dataset(
        &args.left,
        args.left_format.as_deref(),
        args.lenient,
        total_start,
    )
    .with_context(|| format!("failed to normalize {}", args.left.display()))?;

    eprintln!(
        "[{:>8}] normalizing right: {}",
        format_duration(total_start.elapsed()),
        args.right.display()
    );
    let right = normalize_dataset(
        &args.right,
        args.right_format.as_deref(),
        args.lenient,
        total_start,
    )
    .with_context(|| format!("failed to normalize {}", args.right.display()))?;

    eprintln!(
        "[{:>8}] comparing normalized quads",
        format_duration(total_start.elapsed())
    );
    let removed = dataset_difference_count(&left, &right);
    let added = dataset_difference_count(&right, &left);

    println!("RDF diff");
    println!("  Left:             {}", args.left.display());
    println!("  Right:            {}", args.right.display());
    println!("  Normalized left:  {}", left.len());
    println!("  Normalized right: {}", right.len());
    println!("  Only left:        {removed}");
    println!("  Only right:       {added}");
    println!(
        "  Elapsed:          {}",
        format_duration(total_start.elapsed())
    );

    let diff_quads = rdf12_diff_quads(&left, &right)?;
    write_rdf12_diff(&args.output, &diff_quads)?;
    println!("  Wrote RDF 1.2:    {}", args.output.display());
    if let Some(path) = args.pretty.as_deref() {
        write_pretty_diff(path, &diff_quads, args.color)?;
        println!("  Wrote pretty:     {}", display_path(Some(path)));
    }

    Ok(())
}

fn analyze_bnodes(args: AnalyzeBnodesArgs) -> Result<()> {
    let total_start = Instant::now();
    let input_path = args.input.as_deref();
    let format = input_format(args.format.as_deref(), input_path)?;
    if !format.supports_datasets() {
        bail!(
            "{} is a graph format, but blank-node dataset analysis needs a dataset format",
            format.name()
        );
    }

    eprintln!(
        "[{:>8}] starting analyze-bnodes input={} format={}",
        format_duration(total_start.elapsed()),
        display_path(input_path),
        format.name()
    );

    let reader = input_reader(input_path)?;
    let mut parser = RdfParser::from_format(format);
    if args.lenient {
        parser = parser.lenient();
    }

    let mut graphs = BTreeMap::<String, GraphBnodeStats>::new();
    let mut quads = 0usize;
    for quad in parser.for_reader(reader) {
        let quad = quad.context("failed to parse RDF quad")?;
        quads += 1;

        let graph_name = graph_name_label(&quad.graph_name);
        let stats = graphs.entry(graph_name).or_default();
        stats.quads += 1;

        if let GraphName::BlankNode(node) = &quad.graph_name {
            stats.note_bnode(node.as_str());
            stats
                .blank_graph_name_nodes
                .insert(node.as_str().to_owned());
        }

        let subject_bnode = match &quad.subject {
            NamedOrBlankNode::BlankNode(node) => {
                let id = node.as_str().to_owned();
                stats.note_bnode(&id);
                *stats.subject_refs.entry(id.clone()).or_default() += 1;
                Some(id)
            }
            NamedOrBlankNode::NamedNode(_) => None,
        };

        let object_bnode = match &quad.object {
            Term::BlankNode(node) => {
                let id = node.as_str().to_owned();
                stats.note_bnode(&id);
                *stats.object_refs.entry(id.clone()).or_default() += 1;
                stats
                    .incoming_examples
                    .entry(id.clone())
                    .or_default()
                    .push_limited(
                        format!("{} {}", subject_label(&quad.subject), quad.predicate),
                        5,
                    );
                Some(id)
            }
            _ => None,
        };

        if let (Some(subject), Some(object)) = (subject_bnode, object_bnode) {
            stats.blank_edges.entry(subject).or_default().push(object);
        }
    }

    let mut totals = BnodeTotals::default();
    let mut graph_rows = Vec::new();
    let mut shared_examples = Vec::new();

    for (graph_name, stats) in &graphs {
        let summary = stats.summary();
        totals.add(&summary);
        graph_rows.push((graph_name, summary));

        for (node, refs) in stats.shared_object_nodes().into_iter().take(args.limit) {
            let examples = stats
                .incoming_examples
                .get(node)
                .map(|examples| examples.join(" | "))
                .unwrap_or_default();
            shared_examples.push((graph_name.clone(), node.clone(), *refs, examples));
        }
    }

    graph_rows.sort_by(|left, right| {
        right
            .1
            .shared_object_nodes
            .cmp(&left.1.shared_object_nodes)
            .then_with(|| right.1.cyclic_blank_nodes.cmp(&left.1.cyclic_blank_nodes))
            .then_with(|| right.1.blank_nodes.cmp(&left.1.blank_nodes))
            .then_with(|| left.0.cmp(right.0))
    });
    shared_examples.sort_by(|left, right| {
        right
            .2
            .cmp(&left.2)
            .then_with(|| left.0.cmp(&right.0))
            .then_with(|| left.1.cmp(&right.1))
    });

    println!("Blank-node analysis");
    println!("  Input:                  {}", display_path(input_path));
    println!("  Quads:                  {quads}");
    println!("  Graphs:                 {}", graphs.len());
    println!("  Graphs with bnodes:     {}", totals.graphs_with_bnodes);
    println!("  Blank nodes:            {}", totals.blank_nodes);
    println!("  Subject bnodes:         {}", totals.subject_blank_nodes);
    println!("  Object bnodes:          {}", totals.object_blank_nodes);
    println!("  Shared object bnodes:   {}", totals.shared_object_nodes);
    println!(
        "  Graphs with shared obj: {}",
        totals.graphs_with_shared_object_nodes
    );
    println!("  Cyclic bnodes:          {}", totals.cyclic_blank_nodes);
    println!("  Graphs with cycles:     {}", totals.graphs_with_cycles);
    println!(
        "  Elapsed:                {}",
        format_duration(total_start.elapsed())
    );

    println!();
    println!("Top graphs by shared object blank nodes");
    println!(
        "{:>8} {:>8} {:>8} {:>8} {:>8}  graph",
        "shared", "cycles", "bnodes", "subj", "obj"
    );
    for (graph_name, summary) in graph_rows.iter().take(args.limit) {
        println!(
            "{:>8} {:>8} {:>8} {:>8} {:>8}  {}",
            summary.shared_object_nodes,
            summary.cyclic_blank_nodes,
            summary.blank_nodes,
            summary.subject_blank_nodes,
            summary.object_blank_nodes,
            graph_name
        );
    }

    println!();
    println!("Shared object blank-node examples");
    for (graph_name, node, refs, examples) in shared_examples.into_iter().take(args.limit) {
        println!("  {graph_name} _:{node} refs={refs} <- {examples}");
    }

    Ok(())
}

fn canonicalize(args: CanonicalizeArgs) -> Result<()> {
    let total_start = Instant::now();
    let input_path = args.input.as_deref();
    let output_path = args.output.as_deref();
    let format = input_format(args.format.as_deref(), input_path)?;
    if !format.supports_datasets() {
        bail!(
            "{} is a graph format, but dataset canonicalization needs a dataset format",
            format.name()
        );
    }

    eprintln!(
        "[{:>8}] starting canonicalize input={} output={} format={}",
        format_duration(total_start.elapsed()),
        display_path(input_path),
        display_path(output_path),
        format.name()
    );

    let read_start = Instant::now();
    eprintln!(
        "[{:>8}] reading dataset",
        format_duration(total_start.elapsed())
    );
    let reader = input_reader(input_path)?;
    let mut parser = RdfParser::from_format(format);
    if args.lenient {
        parser = parser.lenient();
    }

    let mut dataset = Dataset::new();
    let mut parsed = 0usize;
    for quad in parser.for_reader(reader) {
        let quad = quad.context("failed to parse RDF quad")?;
        dataset.insert(&quad);
        parsed += 1;
    }
    eprintln!(
        "[{:>8}] read {parsed} quads in {}",
        format_duration(total_start.elapsed()),
        format_duration(read_start.elapsed())
    );

    let canonicalize_start = Instant::now();
    eprintln!(
        "[{:>8}] canonicalizing blank nodes with {:?}",
        format_duration(total_start.elapsed()),
        args.algorithm
    );
    let algorithm = match args.algorithm {
        Algorithm::Rdfc10 => CanonicalizationAlgorithm::Rdfc10 {
            hash_algorithm: match args.hash {
                HashAlgorithm::Sha256 => CanonicalizationHashAlgorithm::Sha256,
                HashAlgorithm::Sha384 => CanonicalizationHashAlgorithm::Sha384,
            },
        },
        Algorithm::Unstable => CanonicalizationAlgorithm::Unstable,
    };
    dataset.canonicalize(algorithm);
    eprintln!(
        "[{:>8}] canonicalized in {}",
        format_duration(total_start.elapsed()),
        format_duration(canonicalize_start.elapsed())
    );

    let serialize_start = Instant::now();
    eprintln!(
        "[{:>8}] serializing canonical N-Quads",
        format_duration(total_start.elapsed())
    );
    let mut encoded = Vec::new();
    {
        let mut serializer = RdfSerializer::from_format(RdfFormat::NQuads).for_writer(&mut encoded);
        for quad in &dataset {
            serializer
                .serialize_quad(quad)
                .context("failed to serialize canonical N-Quads")?;
        }
        serializer
            .finish()
            .context("failed to finish N-Quads serialization")?;
    }
    eprintln!(
        "[{:>8}] serialized {} bytes in {}",
        format_duration(total_start.elapsed()),
        encoded.len(),
        format_duration(serialize_start.elapsed())
    );

    let sort_start = Instant::now();
    eprintln!(
        "[{:>8}] sorting output lines",
        format_duration(total_start.elapsed())
    );
    let mut lines = encoded.split(|byte| *byte == b'\n').collect::<Vec<_>>();
    if lines.last().is_some_and(|line| line.is_empty()) {
        lines.pop();
    }
    lines.sort_unstable();
    eprintln!(
        "[{:>8}] sorted {} lines in {}",
        format_duration(total_start.elapsed()),
        lines.len(),
        format_duration(sort_start.elapsed())
    );

    let write_start = Instant::now();
    eprintln!(
        "[{:>8}] writing output",
        format_duration(total_start.elapsed())
    );
    let mut writer = output_writer(output_path)?;
    for line in &lines {
        writer.write_all(line)?;
        writer.write_all(b"\n")?;
    }
    writer.flush()?;
    eprintln!(
        "[{:>8}] wrote output in {}",
        format_duration(total_start.elapsed()),
        format_duration(write_start.elapsed())
    );

    eprintln!(
        "[{:>8}] done: canonicalized {parsed} input quads into {} output quads",
        format_duration(total_start.elapsed()),
        lines.len()
    );
    Ok(())
}

fn normalize_dataset(
    path: &Path,
    format: Option<&str>,
    lenient: bool,
    total_start: Instant,
) -> Result<Dataset> {
    let format = input_format(format, Some(path))?;
    if !format.supports_datasets() {
        bail!(
            "{} is a graph format, but RDF dataset diff needs a dataset format",
            format.name()
        );
    }

    let reader = input_reader(Some(path))?;
    let mut parser = RdfParser::from_format(format);
    if lenient {
        parser = parser.lenient();
    }

    let mut graphs = BTreeMap::<String, DiffGraph>::new();
    let mut quads = 0usize;
    for quad in parser.for_reader(reader) {
        let quad = quad.context("failed to parse RDF quad")?;
        quads += 1;
        graphs
            .entry(graph_name_label(&quad.graph_name))
            .or_default()
            .push(quad);
    }

    eprintln!(
        "[{:>8}] parsed {quads} quads across {} graphs",
        format_duration(total_start.elapsed()),
        graphs.len()
    );

    let mut dataset = Dataset::new();
    for (graph_name, graph) in graphs {
        let graph_dataset = graph
            .normalize(&graph_name)
            .with_context(|| format!("failed to normalize graph {graph_name}"))?;
        for quad in graph_dataset.iter() {
            dataset.insert(quad);
        }
    }

    eprintln!(
        "[{:>8}] normalized into {} quads",
        format_duration(total_start.elapsed()),
        dataset.len()
    );
    Ok(dataset)
}

#[derive(Default)]
struct DiffGraph {
    quads: Vec<Quad>,
    graph_name: Option<GraphName>,
    incoming: HashMap<String, usize>,
    outgoing: HashMap<String, Vec<Quad>>,
    blank_edges: HashMap<String, Vec<String>>,
    blank_graph_name_nodes: BTreeSet<String>,
}

impl DiffGraph {
    fn push(&mut self, quad: Quad) {
        self.graph_name
            .get_or_insert_with(|| quad.graph_name.clone());

        if let GraphName::BlankNode(node) = &quad.graph_name {
            self.blank_graph_name_nodes.insert(node.as_str().to_owned());
        }

        let subject_bnode = match &quad.subject {
            NamedOrBlankNode::BlankNode(node) => Some(node.as_str().to_owned()),
            NamedOrBlankNode::NamedNode(_) => None,
        };
        let object_bnode = match &quad.object {
            Term::BlankNode(node) => Some(node.as_str().to_owned()),
            _ => None,
        };

        if let Some(id) = &subject_bnode {
            self.outgoing
                .entry(id.clone())
                .or_default()
                .push(quad.clone());
        }
        if let Some(id) = &object_bnode {
            *self.incoming.entry(id.clone()).or_default() += 1;
        }
        if let (Some(subject), Some(object)) = (subject_bnode, object_bnode) {
            self.blank_edges.entry(subject).or_default().push(object);
        }

        self.quads.push(quad);
    }

    fn normalize(&self, _graph_name: &str) -> Result<Dataset> {
        if !self.blank_graph_name_nodes.is_empty() {
            bail!(
                "blank-node graph names are not supported yet: {}",
                self.blank_graph_name_nodes
                    .iter()
                    .take(5)
                    .map(|id| format!("_:{id}"))
                    .collect::<Vec<_>>()
                    .join(", ")
            );
        }

        let cyclic = count_cyclic_nodes(&self.blank_edges);
        if cyclic > 0 {
            bail!("blank-node cycles are not supported yet: {cyclic} cyclic nodes");
        }

        let mut context = NormalizeContext {
            graph: self,
            hash_memo: HashMap::new(),
        };
        let mut dataset = Dataset::new();

        for quad in &self.quads {
            match &quad.subject {
                NamedOrBlankNode::NamedNode(_) => {
                    dataset.insert(&context.normalize_quad(quad)?);
                }
                NamedOrBlankNode::BlankNode(node) => {
                    let id = node.as_str();
                    if context.should_emit_blank_subject(id) {
                        dataset.insert(&context.normalize_quad(quad)?);
                    }
                }
            }
        }

        Ok(dataset)
    }
}

struct NormalizeContext<'a> {
    graph: &'a DiffGraph,
    hash_memo: HashMap<String, String>,
}

impl NormalizeContext<'_> {
    fn normalize_quad(&mut self, quad: &Quad) -> Result<Quad> {
        Ok(Quad::new(
            self.normalize_subject(&quad.subject),
            quad.predicate.clone(),
            self.normalize_object_term(&quad.object),
            quad.graph_name.clone(),
        ))
    }

    fn normalize_subject(&mut self, subject: &NamedOrBlankNode) -> NamedOrBlankNode {
        match subject {
            NamedOrBlankNode::NamedNode(node) => node.clone().into(),
            NamedOrBlankNode::BlankNode(node) => self.skolem_node(node.as_str()).into(),
        }
    }

    fn normalize_object_term(&mut self, term: &Term) -> Term {
        match term {
            Term::BlankNode(node) => self.normalize_bnode_object(node.as_str()),
            _ => term.clone(),
        }
    }

    fn normalize_term_label(&mut self, term: &Term) -> String {
        match term {
            Term::NamedNode(node) => named_node_label(node.as_str()),
            Term::Literal(literal) => literal.to_string(),
            Term::BlankNode(node) => self.normalize_bnode_label(node.as_str()),
            Term::Triple(triple) => triple.to_string(),
        }
    }

    fn normalize_bnode_object(&mut self, id: &str) -> Term {
        if self.is_shared(id) || self.is_root(id) {
            self.skolem_node(id).into()
        } else {
            let description = self.inline_bnode(id);
            NamedNode::new_unchecked(inline_blank_iri(&description)).into()
        }
    }

    fn normalize_bnode_label(&mut self, id: &str) -> String {
        if self.is_shared(id) || self.is_root(id) {
            named_node_label(self.skolem_node(id).as_str())
        } else {
            self.inline_bnode(id)
        }
    }

    fn should_emit_blank_subject(&self, id: &str) -> bool {
        self.is_shared(id) || self.is_root(id)
    }

    fn is_shared(&self, id: &str) -> bool {
        self.graph.incoming.get(id).copied().unwrap_or_default() > 1
    }

    fn is_root(&self, id: &str) -> bool {
        self.graph.incoming.get(id).copied().unwrap_or_default() == 0
    }

    fn skolem_node(&mut self, id: &str) -> NamedNode {
        NamedNode::new_unchecked(format!("urn:rdfknife:bn:{}", self.component_hash(id)))
    }

    fn component_hash(&mut self, id: &str) -> String {
        if let Some(hash) = self.hash_memo.get(id) {
            return hash.clone();
        }

        let repr = self.inline_bnode(id);
        let hash = hex::encode(Sha256::digest(repr.as_bytes()));
        self.hash_memo.insert(id.to_owned(), hash.clone());
        hash
    }

    fn inline_bnode(&mut self, id: &str) -> String {
        let Some(quads) = self.graph.outgoing.get(id) else {
            return "[]".to_owned();
        };

        let mut properties = quads
            .iter()
            .map(|quad| {
                format!(
                    "{} {}",
                    named_node_label(quad.predicate.as_str()),
                    self.normalize_term_label(&quad.object)
                )
            })
            .collect::<Vec<_>>();
        properties.sort_unstable();
        properties.dedup();

        format!("[ {} ]", properties.join(" ; "))
    }
}

fn named_node_label(iri: &str) -> String {
    format!("<{iri}>")
}

fn inline_blank_iri(description: &str) -> String {
    let hash = hex::encode(Sha256::digest(description.as_bytes()));
    format!("urn:rdfknife:inline:{hash}")
}

fn dataset_difference_count(left: &Dataset, right: &Dataset) -> usize {
    left.iter().filter(|quad| !right.contains(*quad)).count()
}

fn rdf12_diff_quads(left: &Dataset, right: &Dataset) -> Result<Vec<Quad>> {
    let adds = NamedNode::new("https://less.rest/sheaf/diff/adds")?;
    let removes = NamedNode::new("https://less.rest/sheaf/diff/removes")?;
    let mut diff_quads = Vec::new();

    for quad in left.iter().filter(|quad| !right.contains(*quad)) {
        push_rdf12_change(&mut diff_quads, quad.into_owned(), removes.clone())?;
    }
    for quad in right.iter().filter(|quad| !left.contains(*quad)) {
        push_rdf12_change(&mut diff_quads, quad.into_owned(), adds.clone())?;
    }
    diff_quads.sort_by_key(quad_sort_key);
    Ok(diff_quads)
}

fn write_rdf12_diff(path: &Path, diff_quads: &[Quad]) -> Result<()> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let writer = BufWriter::new(
        File::create(path).with_context(|| format!("failed to create {}", path.display()))?,
    );
    let mut serializer = diff_serializer()?.for_writer(writer);
    for quad in diff_quads {
        serializer.serialize_quad(quad)?;
    }
    let mut writer = serializer.finish()?;
    writer.flush()?;
    Ok(())
}

fn push_rdf12_change(
    diff_quads: &mut Vec<Quad>,
    quad: Quad,
    change_predicate: NamedNode,
) -> Result<()> {
    let triple = Triple::new(
        quad.subject.clone(),
        quad.predicate.clone(),
        quad.object.clone(),
    );
    diff_quads.push(Quad::new(
        BlankNode::new("1")?,
        change_predicate,
        Term::from(triple),
        quad.graph_name.clone(),
    ));

    Ok(())
}

fn quad_sort_key(quad: &Quad) -> (String, String, String, String) {
    (
        quad.graph_name.to_string(),
        quad.subject.to_string(),
        quad.predicate.to_string(),
        quad.object.to_string(),
    )
}

#[derive(Default)]
struct PrettyGraphDiff {
    graph_name: GraphName,
    adds: Vec<Triple>,
    removes: Vec<Triple>,
}

struct PrettyColors {
    header: &'static str,
    add: &'static str,
    remove: &'static str,
    dim: &'static str,
    reset: &'static str,
}

impl PrettyColors {
    fn new(enabled: bool) -> Self {
        if enabled {
            Self {
                header: "\x1b[1;36m",
                add: "\x1b[32m",
                remove: "\x1b[31m",
                dim: "\x1b[2m",
                reset: "\x1b[0m",
            }
        } else {
            Self {
                header: "",
                add: "",
                remove: "",
                dim: "",
                reset: "",
            }
        }
    }
}

fn write_pretty_diff(path: &Path, quads: &[Quad], color_mode: ColorMode) -> Result<()> {
    let adds = NamedNode::new("https://less.rest/sheaf/diff/adds")?;
    let removes = NamedNode::new("https://less.rest/sheaf/diff/removes")?;
    let mut graphs = BTreeMap::<String, PrettyGraphDiff>::new();
    for quad in quads {
        let graph = graphs
            .entry(quad.graph_name.to_string())
            .or_insert_with(|| PrettyGraphDiff {
                graph_name: quad.graph_name.clone(),
                ..Default::default()
            });
        let Term::Triple(triple) = &quad.object else {
            bail!("diff quad object was not a quoted triple: {quad}");
        };
        if quad.predicate == adds.as_ref() {
            graph.adds.push((**triple).clone());
        } else if quad.predicate == removes.as_ref() {
            graph.removes.push((**triple).clone());
        } else {
            bail!("unexpected diff predicate: {}", quad.predicate);
        }
    }

    let colors = PrettyColors::new(color_enabled(path, color_mode));
    let mut writer = output_writer(Some(path))?;
    for graph in graphs.values_mut() {
        graph.adds.sort_by_key(triple_sort_key);
        graph.removes.sort_by_key(triple_sort_key);
        write_pretty_graph_diff(&mut writer, graph, &colors)?;
    }
    writer.flush()?;
    Ok(())
}

fn write_pretty_graph_diff(
    writer: &mut impl Write,
    graph: &PrettyGraphDiff,
    colors: &PrettyColors,
) -> Result<()> {
    writeln!(
        writer,
        "{}{}{} {}(+{} -{}){}",
        colors.header,
        format_graph_name(&graph.graph_name),
        colors.reset,
        colors.dim,
        graph.adds.len(),
        graph.removes.len(),
        colors.reset
    )?;
    for triple in &graph.adds {
        writeln!(
            writer,
            "  {}+{} {}",
            colors.add,
            colors.reset,
            format_triple_line(triple)
        )?;
    }
    for triple in &graph.removes {
        writeln!(
            writer,
            "  {}-{} {}",
            colors.remove,
            colors.reset,
            format_triple_line(triple)
        )?;
    }
    writeln!(writer)?;
    Ok(())
}

fn color_enabled(path: &Path, mode: ColorMode) -> bool {
    match mode {
        ColorMode::Always => true,
        ColorMode::Never => false,
        ColorMode::Auto => path.as_os_str() == "-" && io::stdout().is_terminal(),
    }
}

fn triple_sort_key(triple: &Triple) -> (String, String, String) {
    (
        triple.subject.to_string(),
        triple.predicate.to_string(),
        triple.object.to_string(),
    )
}

fn format_triple_term(triple: &Triple) -> String {
    format!(
        "<<( {} {} {} )>>",
        format_subject(&triple.subject),
        format_named_node(&triple.predicate),
        format_term(&triple.object)
    )
}

fn format_triple_line(triple: &Triple) -> String {
    format!(
        "{} {} {}",
        format_subject(&triple.subject),
        format_named_node(&triple.predicate),
        format_term(&triple.object)
    )
}

fn format_graph_name(graph_name: &GraphName) -> String {
    match graph_name {
        GraphName::NamedNode(node) => format_named_node(node),
        GraphName::BlankNode(node) => node.to_string(),
        GraphName::DefaultGraph => "(default graph)".to_owned(),
    }
}

fn format_subject(subject: &NamedOrBlankNode) -> String {
    match subject {
        NamedOrBlankNode::NamedNode(node) => format_named_node(node),
        NamedOrBlankNode::BlankNode(node) => node.to_string(),
    }
}

fn format_term(term: &Term) -> String {
    match term {
        Term::NamedNode(node) => format_named_node(node),
        Term::BlankNode(node) => node.to_string(),
        Term::Literal(literal) => literal.to_string(),
        Term::Triple(triple) => format_triple_term(triple),
    }
}

fn format_named_node(node: &NamedNode) -> String {
    for (prefix, iri) in DIFF_PREFIXES {
        if let Some(local) = node.as_str().strip_prefix(iri) {
            if is_safe_local_name(local) {
                return format!("{prefix}:{local}");
            }
        }
    }
    named_node_label(node.as_str())
}

fn is_safe_local_name(local: &str) -> bool {
    local.is_empty()
        || local
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b'.'))
}

fn diff_serializer() -> Result<RdfSerializer> {
    let mut serializer = RdfSerializer::from_format(RdfFormat::TriG);
    for (prefix, iri) in DIFF_PREFIXES {
        serializer = serializer.with_prefix(*prefix, *iri)?;
    }
    Ok(serializer)
}

const DIFF_PREFIXES: &[(&str, &str)] = &[
    ("", "https://less.rest/sheaf/diff/"),
    ("rdf", "http://www.w3.org/1999/02/22-rdf-syntax-ns#"),
    ("rdfs", "http://www.w3.org/2000/01/rdf-schema#"),
    ("xsd", "http://www.w3.org/2001/XMLSchema#"),
    ("owl", "http://www.w3.org/2002/07/owl#"),
    ("skos", "http://www.w3.org/2004/02/skos/core#"),
    ("dcterms", "http://purl.org/dc/terms/"),
    ("bibo", "http://purl.org/ontology/bibo/"),
    ("cito", "http://purl.org/spar/cito/"),
    ("biro", "http://purl.org/spar/biro/"),
    ("fabio", "http://purl.org/spar/fabio/"),
    ("foaf", "http://xmlns.com/foaf/0.1/"),
    ("prov", "http://www.w3.org/ns/prov#"),
    ("as", "https://www.w3.org/ns/activitystreams#"),
    ("sheaf", "https://less.rest/sheaf/"),
    ("resource", "https://sheaf.less.rest/"),
];

#[derive(Default)]
struct GraphBnodeStats {
    quads: usize,
    blank_nodes: BTreeSet<String>,
    subject_refs: HashMap<String, usize>,
    object_refs: HashMap<String, usize>,
    blank_graph_name_nodes: HashSet<String>,
    blank_edges: HashMap<String, Vec<String>>,
    incoming_examples: HashMap<String, LimitedVec>,
}

impl GraphBnodeStats {
    fn note_bnode(&mut self, id: &str) {
        self.blank_nodes.insert(id.to_owned());
    }

    fn shared_object_nodes(&self) -> Vec<(&String, &usize)> {
        let mut nodes = self
            .object_refs
            .iter()
            .filter(|(_, refs)| **refs > 1)
            .collect::<Vec<_>>();
        nodes.sort_by(|left, right| right.1.cmp(left.1).then_with(|| left.0.cmp(right.0)));
        nodes
    }

    fn summary(&self) -> GraphBnodeSummary {
        GraphBnodeSummary {
            blank_nodes: self.blank_nodes.len(),
            subject_blank_nodes: self.subject_refs.len(),
            object_blank_nodes: self.object_refs.len(),
            graph_name_blank_nodes: self.blank_graph_name_nodes.len(),
            shared_object_nodes: self.object_refs.values().filter(|refs| **refs > 1).count(),
            cyclic_blank_nodes: count_cyclic_nodes(&self.blank_edges),
        }
    }
}

#[derive(Clone, Copy, Default)]
struct GraphBnodeSummary {
    blank_nodes: usize,
    subject_blank_nodes: usize,
    object_blank_nodes: usize,
    graph_name_blank_nodes: usize,
    shared_object_nodes: usize,
    cyclic_blank_nodes: usize,
}

#[derive(Default)]
struct BnodeTotals {
    graphs_with_bnodes: usize,
    graphs_with_shared_object_nodes: usize,
    graphs_with_cycles: usize,
    blank_nodes: usize,
    subject_blank_nodes: usize,
    object_blank_nodes: usize,
    graph_name_blank_nodes: usize,
    shared_object_nodes: usize,
    cyclic_blank_nodes: usize,
}

impl BnodeTotals {
    fn add(&mut self, summary: &GraphBnodeSummary) {
        self.graphs_with_bnodes += usize::from(summary.blank_nodes > 0);
        self.graphs_with_shared_object_nodes += usize::from(summary.shared_object_nodes > 0);
        self.graphs_with_cycles += usize::from(summary.cyclic_blank_nodes > 0);
        self.blank_nodes += summary.blank_nodes;
        self.subject_blank_nodes += summary.subject_blank_nodes;
        self.object_blank_nodes += summary.object_blank_nodes;
        self.graph_name_blank_nodes += summary.graph_name_blank_nodes;
        self.shared_object_nodes += summary.shared_object_nodes;
        self.cyclic_blank_nodes += summary.cyclic_blank_nodes;
    }
}

#[derive(Default)]
struct LimitedVec(Vec<String>);

impl LimitedVec {
    fn push_limited(&mut self, value: String, limit: usize) {
        if self.0.len() < limit {
            self.0.push(value);
        }
    }

    fn join(&self, separator: &str) -> String {
        self.0.join(separator)
    }
}

fn count_cyclic_nodes(edges: &HashMap<String, Vec<String>>) -> usize {
    let mut index = 0usize;
    let mut stack = Vec::<String>::new();
    let mut states = HashMap::<String, TarjanState>::new();
    let mut cyclic = 0usize;

    let mut nodes = BTreeSet::<String>::new();
    for (from, targets) in edges {
        nodes.insert(from.clone());
        nodes.extend(targets.iter().cloned());
    }

    for node in nodes {
        if !states.contains_key(&node) {
            strong_connect(
                &node,
                edges,
                &mut index,
                &mut stack,
                &mut states,
                &mut cyclic,
            );
        }
    }

    cyclic
}

#[derive(Clone, Copy)]
struct TarjanState {
    index: usize,
    lowlink: usize,
    on_stack: bool,
}

fn strong_connect(
    node: &str,
    edges: &HashMap<String, Vec<String>>,
    index: &mut usize,
    stack: &mut Vec<String>,
    states: &mut HashMap<String, TarjanState>,
    cyclic: &mut usize,
) {
    let node_index = *index;
    *index += 1;
    states.insert(
        node.to_owned(),
        TarjanState {
            index: node_index,
            lowlink: node_index,
            on_stack: true,
        },
    );
    stack.push(node.to_owned());

    for target in edges.get(node).into_iter().flatten() {
        if !states.contains_key(target) {
            strong_connect(target, edges, index, stack, states, cyclic);
            let target_lowlink = states[target].lowlink;
            states.get_mut(node).unwrap().lowlink = states[node].lowlink.min(target_lowlink);
        } else if states[target].on_stack {
            let target_index = states[target].index;
            states.get_mut(node).unwrap().lowlink = states[node].lowlink.min(target_index);
        }
    }

    let state = states[node];
    if state.lowlink == state.index {
        let mut component = Vec::new();
        while let Some(member) = stack.pop() {
            states.get_mut(&member).unwrap().on_stack = false;
            let done = member == node;
            component.push(member);
            if done {
                break;
            }
        }

        let self_loop = component.len() == 1
            && edges
                .get(&component[0])
                .is_some_and(|targets| targets.iter().any(|target| target == &component[0]));
        if component.len() > 1 || self_loop {
            *cyclic += component.len();
        }
    }
}

fn graph_name_label(graph_name: &GraphName) -> String {
    match graph_name {
        GraphName::DefaultGraph => "DEFAULT".to_owned(),
        GraphName::NamedNode(node) => format!("<{}>", node.as_str()),
        GraphName::BlankNode(node) => format!("_:{}", node.as_str()),
    }
}

fn subject_label(subject: &NamedOrBlankNode) -> String {
    match subject {
        NamedOrBlankNode::NamedNode(node) => format!("<{}>", node.as_str()),
        NamedOrBlankNode::BlankNode(node) => format!("_:{}", node.as_str()),
    }
}

fn display_path(path: Option<&Path>) -> String {
    match path {
        Some(path) if path.as_os_str() != "-" => path.display().to_string(),
        _ => "-".to_owned(),
    }
}

fn format_duration(duration: Duration) -> String {
    let millis = duration.as_millis();
    if millis < 1_000 {
        format!("{millis}ms")
    } else {
        let seconds = duration.as_secs();
        let millis = duration.subsec_millis();
        format!("{seconds}.{millis:03}s")
    }
}

fn input_format(format: Option<&str>, input_path: Option<&Path>) -> Result<RdfFormat> {
    if let Some(format) = format {
        return parse_format(format).with_context(|| format!("unknown RDF format: {format}"));
    }

    let Some(path) = input_path.filter(|path| path.as_os_str() != "-") else {
        return Ok(RdfFormat::NQuads);
    };

    let path = strip_gz_extension(path);
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .context("could not infer RDF format from input extension; pass --format")?;
    parse_format(extension).with_context(|| {
        format!("could not infer RDF format from extension .{extension}; pass --format")
    })
}

fn parse_format(format: &str) -> Option<RdfFormat> {
    RdfFormat::from_extension(format).or_else(|| RdfFormat::from_media_type(format))
}

fn strip_gz_extension(path: &Path) -> PathBuf {
    if path.extension().and_then(|extension| extension.to_str()) == Some("gz") {
        path.with_extension("")
    } else {
        path.to_owned()
    }
}

fn input_reader(path: Option<&Path>) -> Result<Box<dyn Read>> {
    let Some(path) = path.filter(|path| path.as_os_str() != "-") else {
        return Ok(Box::new(BufReader::new(io::stdin())));
    };

    let file = File::open(path).with_context(|| format!("failed to open {}", path.display()))?;
    let reader: Box<dyn Read> =
        if path.extension().and_then(|extension| extension.to_str()) == Some("gz") {
            Box::new(BufReader::new(GzDecoder::new(file)))
        } else {
            Box::new(BufReader::new(file))
        };
    Ok(reader)
}

fn output_writer(path: Option<&Path>) -> Result<Box<dyn Write>> {
    let Some(path) = path.filter(|path| path.as_os_str() != "-") else {
        return Ok(Box::new(BufWriter::new(io::stdout())));
    };

    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }

    let file =
        File::create(path).with_context(|| format!("failed to create {}", path.display()))?;
    let writer: Box<dyn Write> =
        if path.extension().and_then(|extension| extension.to_str()) == Some("gz") {
            Box::new(BufWriter::new(GzEncoder::new(file, Compression::default())))
        } else {
            Box::new(BufWriter::new(file))
        };
    Ok(writer)
}
