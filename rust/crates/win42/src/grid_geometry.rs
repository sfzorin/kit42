//! Pure geometry for the native variable-size grid.
use crate::GridRange;
pub(crate) fn offsets(lengths: &[i32]) -> Vec<i32> {
    let mut out = Vec::with_capacity(lengths.len() + 1);
    out.push(0i32);
    for v in lengths {
        out.push(
            out.last()
                .copied()
                .unwrap_or(0)
                .saturating_add((*v).clamp(1, 65535)),
        )
    }
    out
}
pub(crate) fn index_at(offsets: &[i32], value: i32) -> Option<usize> {
    if value < 0 || value >= *offsets.last()? {
        return None;
    }
    Some(offsets.partition_point(|v| *v <= value).saturating_sub(1))
}
pub(crate) fn bounds(
    row: usize,
    col: usize,
    merge: Option<GridRange>,
    xs: &[i32],
    ys: &[i32],
    scroll_x: i32,
    scroll_y: i32,
    header_x: i32,
    header_y: i32,
) -> Option<(i32, i32, i32, i32)> {
    let m = merge.unwrap_or(GridRange {
        top: row,
        left: col,
        bottom: row,
        right: col,
    });
    if m.top > m.bottom
        || m.left > m.right
        || m.bottom.checked_add(1)? >= ys.len()
        || m.right.checked_add(1)? >= xs.len()
    {
        return None;
    }
    Some((
        header_x + xs[m.left] - scroll_x,
        header_y + ys[m.top] - scroll_y,
        header_x + xs[m.right + 1] - scroll_x,
        header_y + ys[m.bottom + 1] - scroll_y,
    ))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn variable_offsets_hit_and_scrolled_merged_bounds() {
        let x = offsets(&[50, 120, 10]);
        let y = offsets(&[20, 60, 5]);
        assert_eq!(x, [0, 50, 170, 180]);
        assert_eq!(y, [0, 20, 80, 85]);
        assert_eq!(index_at(&x, 49), Some(0));
        assert_eq!(index_at(&x, 50), Some(1));
        assert_eq!(index_at(&y, 79), Some(1));
        assert_eq!(index_at(&y, 85), None);
        let merge = GridRange {
            top: 0,
            left: 1,
            bottom: 1,
            right: 2,
        };
        assert_eq!(
            bounds(0, 1, Some(merge), &x, &y, 15, 10, 48, 25),
            Some((83, 15, 213, 95))
        );
        assert!(bounds(
            0,
            0,
            Some(GridRange {
                top: 0,
                left: 0,
                bottom: 99,
                right: 0
            }),
            &x,
            &y,
            0,
            0,
            48,
            25
        )
        .is_none());
    }
}
