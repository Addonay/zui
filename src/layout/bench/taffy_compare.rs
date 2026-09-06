//! Small release-mode Taffy reference runner used by ZUI's comparison report.
//!
//! This intentionally uses the same setup/timing boundary as the Zig runner:
//! each tree is built fresh outside `Instant::now()` and only the cold layout
//! call is measured. It is not a Criterion replacement; its job is to produce
//! stable, machine-readable overlap points for the fixed-capacity ZUI engine.

use std::{hint::black_box, time::Instant};
use taffy::prelude::*;

struct Stats {
    total_ns: u128,
    checksum: f32,
}

fn flat_flex(nodes: usize, iterations: usize) -> Stats {
    let mut total_ns = 0;
    let mut checksum = 0.0;
    for _ in 0..iterations {
        let mut tree: TaffyTree<()> = TaffyTree::new();
        let child_style = Style { size: Size { width: length(10.0), height: length(20.0) }, ..Default::default() };
        let children: Vec<_> = (0..nodes).map(|_| tree.new_leaf(child_style.clone()).unwrap()).collect();
        let root = tree.new_with_children(Style::default(), &children).unwrap();
        let start = Instant::now();
        tree.compute_layout(root, Size { width: length(12000.0), height: length(8000.0) }).unwrap();
        total_ns += start.elapsed().as_nanos();
        checksum += tree.layout(root).unwrap().size.width + tree.layout(root).unwrap().size.height;
        black_box(&tree);
    }
    Stats { total_ns, checksum }
}

fn tree_creation(nodes: usize, iterations: usize) -> Stats {
    let mut total_ns = 0;
    let mut checksum = 0.0;
    for _ in 0..iterations {
        let start = Instant::now();
        let mut tree: TaffyTree<()> = TaffyTree::new();
        let child_style = Style { size: Size { width: length(10.0), height: length(20.0) }, ..Default::default() };
        let mut children = Vec::new();
        let mut created = 0;
        while created < nodes {
            let group_children: Vec<_> = (0..4).map(|_| tree.new_leaf(child_style.clone()).unwrap()).collect();
            let group = tree.new_with_children(Style::default(), &group_children).unwrap();
            children.push(group);
            created += 5;
        }
        let _root = tree.new_with_children(Style::default(), &children).unwrap();
        total_ns += start.elapsed().as_nanos();
        checksum += tree.total_node_count() as f32;
        black_box(&tree);
    }
    Stats { total_ns, checksum }
}

fn grid_wide(tracks: usize, iterations: usize) -> Stats {
    let mut total_ns = 0;
    let mut checksum = 0.0;
    for _ in 0..iterations {
        let mut tree: TaffyTree<()> = TaffyTree::new();
        let columns: Vec<_> = (0..tracks).map(|_| fr(1.0)).collect();
        let rows: Vec<_> = (0..tracks).map(|_| fr(1.0)).collect();
        let style = Style { display: Display::Grid, grid_template_columns: columns, grid_template_rows: rows, ..Default::default() };
        let child_style = Style { size: Size { width: length(20.0), height: length(20.0) }, ..Default::default() };
        let children: Vec<_> = (0..tracks * tracks).map(|_| tree.new_leaf(child_style.clone()).unwrap()).collect();
        let root = tree.new_with_children(style, &children).unwrap();
        let start = Instant::now();
        tree.compute_layout(root, Size { width: length(12000.0), height: length(8000.0) }).unwrap();
        total_ns += start.elapsed().as_nanos();
        checksum += tree.layout(root).unwrap().size.width + tree.layout(root).unwrap().size.height;
        black_box(&tree);
    }
    Stats { total_ns, checksum }
}

fn deep_chain(depth: usize, iterations: usize) -> Stats {
    let mut total_ns = 0;
    let mut checksum = 0.0;
    for _ in 0..iterations {
        let mut tree: TaffyTree<()> = TaffyTree::new();
        let mut node = tree.new_leaf(Style { flex_grow: 1.0, margin: length(10.0), ..Default::default() }).unwrap();
        for _ in 1..depth {
            node = tree.new_with_children(Style { flex_grow: 1.0, margin: length(10.0), ..Default::default() }, &[node]).unwrap();
        }
        let start = Instant::now();
        tree.compute_layout(node, Size { width: length(12000.0), height: length(8000.0) }).unwrap();
        total_ns += start.elapsed().as_nanos();
        checksum += tree.layout(node).unwrap().size.width + tree.layout(node).unwrap().size.height;
        black_box(&tree);
    }
    Stats { total_ns, checksum }
}

fn deep_grid_node(tree: &mut TaffyTree<()>, levels: usize, tracks: usize) -> NodeId {
    let columns: Vec<_> = (0..tracks).map(|_| fr(1.0)).collect();
    let rows: Vec<_> = (0..tracks).map(|_| fr(1.0)).collect();
    if levels == 0 {
        return tree.new_leaf(Style { size: Size { width: length(20.0), height: length(20.0) }, ..Default::default() }).unwrap();
    }
    let children: Vec<_> = (0..tracks * tracks).map(|_| deep_grid_node(tree, levels - 1, tracks)).collect();
    tree.new_with_children(
        Style { display: Display::Grid, grid_template_columns: columns, grid_template_rows: rows, ..Default::default() },
        &children,
    ).unwrap()
}

fn deep_grid(levels: usize, tracks: usize, iterations: usize) -> Stats {
    let mut total_ns = 0;
    let mut checksum = 0.0;
    for _ in 0..iterations {
        let mut tree: TaffyTree<()> = TaffyTree::new();
        let inner = deep_grid_node(&mut tree, levels, tracks);
        let root = tree.new_with_children(Style::default(), &[inner]).unwrap();
        let start = Instant::now();
        tree.compute_layout(root, Size { width: length(12000.0), height: length(8000.0) }).unwrap();
        total_ns += start.elapsed().as_nanos();
        checksum += tree.layout(root).unwrap().size.width + tree.layout(root).unwrap().size.height;
        black_box(&tree);
    }
    Stats { total_ns, checksum }
}

fn print_row(suite: &str, case_name: &str, nodes: usize, iterations: usize, stats: Stats) {
    let mean = stats.total_ns as f64 / iterations as f64;
    let per_second = if mean == 0.0 { 0.0 } else { 1_000_000_000.0 / mean };
    println!("| {suite} | {case_name} | {nodes} | {iterations} | {mean:.1} | {per_second:.0} | {:.1} |", stats.checksum);
}

fn main() {
    println!("# Taffy 0.14 Reference Benchmark Results\n");
    println!("Built with `cargo build --release`; tree-creation rows time construction, layout rows time only `compute_layout`, with setup outside the timed interval.\n");
    println!("| suite | case | nodes | iterations | ns/layout | layouts/s | checksum |\n|---|---|---:|---:|---:|---:|---:|");
    for (nodes, iterations) in [(1000, 50), (3000, 20), (10000, 5), (100000, 1)] {
        eprintln!("running taffy tree creation {nodes} nodes");
        print_row("tree_creation", "new + children", nodes, iterations, tree_creation(nodes, iterations));
    }
    for (nodes, iterations) in [(1000, 20), (3000, 10), (10000, 5), (100000, 1)] {
        eprintln!("running taffy flex {nodes} nodes");
        print_row("flex_flat", "row", nodes, iterations, flat_flex(nodes, iterations));
    }
    for (tracks, iterations) in [(4, 20), (16, 10), (31, 5), (63, 3), (100, 1), (316, 1)] {
        eprintln!("running taffy grid {tracks}x{tracks}");
        print_row("grid_wide", &format!("{tracks}x{tracks}"), tracks * tracks + 1, iterations, grid_wide(tracks, iterations));
    }
    for (tracks, levels, iterations, nodes) in [(2, 5, 5, 1366), (3, 4, 10, 7382), (2, 7, 1, 21846)] {
        eprintln!("running taffy grid deep {tracks}x{tracks}, {levels} levels");
        print_row("grid_deep", &format!("{tracks}x{tracks}, {levels} levels"), nodes, iterations, deep_grid(levels, tracks, iterations));
    }
    for (levels, iterations) in [(100, 5), (1000, 1)] {
        eprintln!("running taffy grid superdeep depth {levels}");
        print_row("grid_superdeep", &format!("1x1, depth {levels}"), levels + 1, iterations, deep_grid(levels, 1, iterations));
    }
    for (depth, iterations) in [(50, 20), (100, 10)] {
        eprintln!("running taffy deep chain depth {depth}");
        print_row("deep_chain", &format!("depth {depth}"), depth, iterations, deep_chain(depth, iterations));
    }
}
