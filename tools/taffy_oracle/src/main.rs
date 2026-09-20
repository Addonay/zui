use taffy::prelude::*;
use taffy::tree::TaffyError;

fn emit(name: &str, tree: &TaffyTree<()>, nodes: &[NodeId]) -> Result<(), TaffyError> {
    for (index, node) in nodes.iter().enumerate() {
        let layout = tree.layout(*node)?;
        println!(
            "{name}|{index}|{:.3}|{:.3}|{:.3}|{:.3}",
            layout.location.x,
            layout.location.y,
            layout.size.width,
            layout.size.height
        );
    }
    Ok(())
}

fn row_gap_padding() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style {
        size: Size { width: length(30.0), height: length(20.0) },
        ..Default::default()
    })?;
    let second = tree.new_leaf(Style {
        size: Size { width: auto(), height: length(20.0) },
        flex_grow: 1.0,
        flex_basis: length(0.0),
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style {
            size: Size { width: length(200.0), height: length(100.0) },
            flex_direction: FlexDirection::Row,
            gap: Size { width: length(3.0), height: zero() },
            padding: Rect { left: length(10.0), right: length(10.0), top: length(10.0), bottom: length(10.0) },
            ..Default::default()
        },
        &[first, second],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(200.0), height: AvailableSpace::Definite(100.0) })?;
    emit("row_gap_padding", &tree, &[root, first, second])
}

fn percentage_nested() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let grandchild = tree.new_leaf(Style {
        size: Size { width: percent(1.0), height: percent(1.0) },
        ..Default::default()
    })?;
    let child = tree.new_with_children(
        Style {
            size: Size { width: percent(1.0), height: percent(1.0) },
            padding: Rect::length(5.0),
            ..Default::default()
        },
        &[grandchild],
    )?;
    let root = tree.new_with_children(
        Style {
            size: Size { width: length(200.0), height: length(120.0) },
            padding: Rect::length(10.0),
            ..Default::default()
        },
        &[child],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(200.0), height: AvailableSpace::Definite(120.0) })?;
    // Taffy reports each location relative to its parent; ZUI copies absolute
    // bounds into its frame. Accumulate the nested locations for a like-for-
    // like oracle record.
    let root_layout = tree.layout(root)?;
    let child_layout = tree.layout(child)?;
    let grand_layout = tree.layout(grandchild)?;
    println!("percentage_nested|0|{:.3}|{:.3}|{:.3}|{:.3}", root_layout.location.x, root_layout.location.y, root_layout.size.width, root_layout.size.height);
    println!("percentage_nested|1|{:.3}|{:.3}|{:.3}|{:.3}", root_layout.location.x + child_layout.location.x, root_layout.location.y + child_layout.location.y, child_layout.size.width, child_layout.size.height);
    println!("percentage_nested|2|{:.3}|{:.3}|{:.3}|{:.3}", root_layout.location.x + child_layout.location.x + grand_layout.location.x, root_layout.location.y + child_layout.location.y + grand_layout.location.y, grand_layout.size.width, grand_layout.size.height);
    Ok(())
}

fn authored_percentage() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let child = tree.new_leaf(Style {
        size: Size { width: percent(0.5), height: percent(0.5) },
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style { size: Size { width: length(200.0), height: length(120.0) }, ..Default::default() },
        &[child],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(200.0), height: AvailableSpace::Definite(120.0) })?;
    emit("authored_percentage", &tree, &[root, child])
}

fn wrap_absolute() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let child = |tree: &mut TaffyTree<()>| {
        tree.new_leaf(Style { size: Size { width: length(40.0), height: length(10.0) }, ..Default::default() })
    };
    let first = child(&mut tree)?;
    let second = child(&mut tree)?;
    let third = child(&mut tree)?;
    let anchored = tree.new_leaf(Style {
        position: Position::Absolute,
        size: Size { width: length(8.0), height: length(8.0) },
        inset: Rect { top: length(4.0), right: length(3.0), ..Rect::AUTO },
        ..Default::default()
    })?;
    let inset = tree.new_leaf(Style {
        position: Position::Absolute,
        inset: Rect::length(7.0),
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style {
            size: Size { width: length(100.0), height: length(100.0) },
            flex_direction: FlexDirection::Row,
            flex_wrap: FlexWrap::Wrap,
            gap: Size { width: length(4.0), height: length(4.0) },
            ..Default::default()
        },
        &[first, second, third, anchored, inset],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(100.0) })?;
    emit("wrap_absolute", &tree, &[root, first, second, third, anchored, inset])
}

fn center_between() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style { size: Size { width: length(10.0), height: length(10.0) }, ..Default::default() })?;
    let second = tree.new_leaf(Style { size: Size { width: length(30.0), height: length(20.0) }, ..Default::default() })?;
    let root = tree.new_with_children(
        Style {
            size: Size { width: length(100.0), height: length(50.0) },
            align_items: Some(AlignItems::CENTER),
            justify_content: Some(JustifyContent::SPACE_BETWEEN),
            padding: Rect::length(4.0),
            ..Default::default()
        },
        &[first, second],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(50.0) })?;
    emit("center_between", &tree, &[root, first, second])
}

fn min_max() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let child = tree.new_leaf(Style {
        size: Size { width: auto(), height: length(20.0) },
        min_size: Size { width: length(60.0), height: auto() },
        max_size: Size { width: length(80.0), height: auto() },
        flex_grow: 1.0,
        flex_basis: length(0.0),
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style { size: Size { width: length(100.0), height: length(20.0) }, ..Default::default() },
        &[child],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(20.0) })?;
    emit("min_max", &tree, &[root, child])
}

fn grid_basic() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style {
        size: Size { width: auto(), height: length(20.0) },
        grid_column: Line { start: line(1), end: line(2) },
        ..Default::default()
    })?;
    let second = tree.new_leaf(Style {
        size: Size { width: auto(), height: length(20.0) },
        grid_column: Line { start: line(2), end: line(3) },
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style {
            display: Display::Grid,
            size: Size { width: length(100.0), height: length(50.0) },
            grid_template_columns: vec![length(40.0), fr(1.0)],
            grid_template_rows: vec![length(20.0)],
            ..Default::default()
        },
        &[first, second],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(50.0) })?;
    emit("grid_basic", &tree, &[root, first, second])
}

fn grid_column_flow() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style { size: Size { width: auto(), height: auto() }, ..Default::default() })?;
    let second = tree.new_leaf(Style { size: Size { width: auto(), height: auto() }, ..Default::default() })?;
    let third = tree.new_leaf(Style { size: Size { width: auto(), height: auto() }, ..Default::default() })?;
    let root = tree.new_with_children(
        Style {
            display: Display::Grid,
            size: Size { width: length(100.0), height: length(40.0) },
            grid_template_columns: vec![length(50.0), length(50.0)],
            grid_template_rows: vec![length(20.0), length(20.0)],
            grid_auto_flow: GridAutoFlow::Column,
            ..Default::default()
        },
        &[first, second, third],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(40.0) })?;
    emit("grid_column_flow", &tree, &[root, first, second, third])
}

fn aspect_ratio() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let child = tree.new_leaf(Style {
        size: Size { width: length(80.0), height: auto() },
        aspect_ratio: Some(2.0),
        ..Default::default()
    })?;
    let root = tree.new_with_children(
        Style { size: Size { width: length(100.0), height: length(60.0) }, ..Default::default() },
        &[child],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(60.0) })?;
    emit("aspect_ratio", &tree, &[root, child])
}

fn reverse_flow() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style { size: Size { width: length(30.0), height: length(20.0) }, ..Default::default() })?;
    let second = tree.new_leaf(Style { size: Size { width: length(20.0), height: length(20.0) }, ..Default::default() })?;
    let root = tree.new_with_children(
        Style {
            flex_direction: FlexDirection::RowReverse,
            size: Size { width: length(100.0), height: length(20.0) },
            ..Default::default()
        },
        &[first, second],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(20.0) })?;
    emit("reverse_flow", &tree, &[root, first, second])
}

fn wrap_reverse() -> Result<(), TaffyError> {
    let mut tree: TaffyTree<()> = TaffyTree::new();
    let first = tree.new_leaf(Style { size: Size { width: length(40.0), height: length(10.0) }, ..Default::default() })?;
    let second = tree.new_leaf(Style { size: Size { width: length(40.0), height: length(10.0) }, ..Default::default() })?;
    let third = tree.new_leaf(Style { size: Size { width: length(40.0), height: length(10.0) }, ..Default::default() })?;
    let root = tree.new_with_children(
        Style {
            flex_direction: FlexDirection::Row,
            flex_wrap: FlexWrap::WrapReverse,
            size: Size { width: length(100.0), height: length(100.0) },
            ..Default::default()
        },
        &[first, second, third],
    )?;
    tree.compute_layout(root, Size { width: AvailableSpace::Definite(100.0), height: AvailableSpace::Definite(100.0) })?;
    emit("wrap_reverse", &tree, &[root, first, second, third])
}

fn main() -> Result<(), TaffyError> {
    row_gap_padding()?;
    percentage_nested()?;
    authored_percentage()?;
    wrap_absolute()?;
    center_between()?;
    min_max()?;
    grid_basic()?;
    grid_column_flow()?;
    aspect_ratio()?;
    reverse_flow()?;
    wrap_reverse()
}
