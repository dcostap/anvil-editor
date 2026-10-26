use crate::geometry::{Aabb, Ray};

pub struct Bvh {
    nodes: Vec<Node>,
}

enum Node {
    Leaf { bounds: Aabb, first: u32, count: u32 },
    Branch { bounds: Aabb, left: u32, right: u32 },
}

impl Bvh {
    pub fn hit(&self, ray: &Ray, t_max: f32) -> Option<u32> {
        let mut stack = vec![0u32];
        let mut best = None;
        while let Some(index) = stack.pop() {
            match &self.nodes[index as usize] {
                Node::Leaf { bounds, first, .. } if bounds.hit(ray, t_max) => best = Some(*first),
                Node::Branch { bounds, left, right } if bounds.hit(ray, t_max) => stack.extend([*left, *right]),
                _ => {}
            }
        }
        best
    }
}
