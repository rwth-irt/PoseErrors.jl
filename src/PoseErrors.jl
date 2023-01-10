module PoseErrors

export add_error
export adds_error
export mdds_error
export model_diameter
export pdm_avg_recall
export surface_discrepancy
export vsd_avg_recall
export vsd_error
export vsd_errors_bop19

# Geometry
using CoordinateTransformations
using Distances
using GeometryBasics: Mesh
using Rotations
using StaticArrays

# Matching points and calculating distances ADD-S & MDD-S
using Base.Iterators: drop
using NearestNeighbors
using Statistics

# For projection based methods
using SciGL

# Point Distance Metrics

"""
    add_error(points, estimate, ground_truth)
Average Distance of Model Points for objects with no indistinguishable views (Hinterstoisser et al. 2012).
Reimplementation of [https://github.com/thodan/bop_toolkit/blob/master/bop_toolkit_lib/pose_error.py](BOP-toolkit).
"""
add_error(points, estimate, ground_truth) = mean(model_point_distances(points, estimate, ground_truth))

"""
    adds_error(points, estimate, ground_truth)
Average Distance of Model Points for objects with indistinguishable views (Hinterstoisser et al. 2012).
Also known as ADD-S or ADI.
Reimplementation of [https://github.com/thodan/bop_toolkit/blob/master/bop_toolkit_lib/pose_error.py](BOP-toolkit).
"""
adds_error(points, estimate, ground_truth) = mean(nearest_neighbor_distances(points, estimate, ground_truth))

"""
    mdds_error(points, estimate, ground_truth)
Maximum Distance of Model Points for objects with indistinguishable views.
Adaption of the ADD-S error to avoid higher frequency surface features and provide a better indicator for grasp success.
Compared to the Maximum Symmetry-Aware Surface Distance (MSSD) used in the BOP challenge, this method avoids having to define / identify symmetries explicitly.
"""
mdds_error(points, estimate, ground_truth) = maximum(nearest_neighbor_distances(points, estimate, ground_truth))

"""
    nearest_neighbor_distances(points, estimate, ground_truth)
Returns the distance of each ground truth point to it's corresponding nearest neighbor in the estimates.
"""
function nearest_neighbor_distances(points, estimate, ground_truth)
    es_points = transform_points(points, estimate)
    gt_points = transform_points(points, ground_truth)

    tree = KDTree(es_points, Euclidean())
    _, distances = nn(tree, gt_points)
    return distances
end

"""
    model_point_distances(points, estimate, ground_truth)
Returns the distance of each ground truth model point to it's corresponding model point in the estimates.
"""
function model_point_distances(points, estimate, ground_truth)
    es_points = transform_points(points, estimate)
    gt_points = transform_points(points, ground_truth)
    colwise(Euclidean(), es_points, gt_points)
end

"""
    transform_points(points, pose)
Returns an AbstractVector{<:SVector} which can be processed by NearestNeighbors.jl
"""
transform_points(points::AbstractVector{<:AbstractVector}, pose::AffineMap) = pose.(convert_points(points))
transform_points(points::AbstractMatrix, pose) = transform_points(convert_points(points), pose)

"""
    model_diameter(points)
Calculate the maximum distance of two points in the model which is the diameter of the object.
"""
function model_diameter(points)
    # Distances.jl does not like the StaticArray implementation of GeometryBasics.jl
    points = convert_points(points)
    # Type stable zero initialization
    diameter = evaluate(Euclidean(), first(points), first(points))
    for (idx, point_a) in enumerate(points)
        # Previous and current point do not need to be compared again
        for point_b in drop(points, idx)
            dist = evaluate(Euclidean(), point_a, point_b)
            diameter = dist > diameter ? dist : diameter
        end
    end
    return diameter
end

"""
    convert_points(points)
Support different point formats: vectors of points/vectors, meshes, matrices [point,n_points]
"""
convert_points(points::AbstractVector{<:AbstractVector}) = SVector{3}.(points)
convert_points(points::AbstractMatrix) = [SVector{3}(x) for x in eachcol(points)]
convert_points(points::Mesh) = convert_points(points.position)

# Projection / Rendering Based Metrics

"""
    vsd_errors_bop19(depth_context, estimate, ground_truth, measurement, diameter, [δ=15e-3])
Calculate the visible surface discrepancy errors according to [BOP19](https://bop.felk.cvut.cz/challenges/bop-challenge-2019/) by increasing τ as 5%:5%:50% of the object diameter `⌀`.
δ is used as tolerance for the visibility masks.
"""
function vsd_errors_bop19(depth_context::OffscreenContext, estimate::Scene, ground_truth::Scene, measurement::AbstractArray, diameter, δ=15e-3)
    # 5%-50% of the object diameter in 5% steps
    taus = [t * diameter for t in 5e-2:5e-2:50e-2]
    [vsd_error(depth_context, estimate, ground_truth, measurement, δ, τ) for τ in taus]
end

"""
    vsd_error(depth_context, estimate, ground_truth, measurement, δ, τ)
Calculate the visible surface discrepancy according to [BOP19](https://bop.felk.cvut.cz/challenges/bop-challenge-2019/).
δ is used as tolerance for the visibility masks and τ is the misalignment tolerance.
"""
function vsd_error(depth_context::OffscreenContext, estimate::Scene, ground_truth::Scene, measurement::AbstractArray, δ, τ)
    es_img, gt_img = draw_distance(depth_context, estimate, ground_truth)
    visible_es, visible_gt = pixel_visible.(es_img, measurement, δ), pixel_visible.(gt_img, measurement, δ)
    surface_discrepancy(visible_es, visible_gt, τ)
end

"""
    pixel_visible(render, measurement, δ)
If the rendered pixel is in front of the measurement with a tolerance of δ, the render distance is returned.
Otherwise, zero is returned.
"""
function pixel_visible(render, measurement, δ)
    # BOP19 convention: No depth value is considered visible
    if measurement <= 0
        return render
    end
    render <= measurement + δ ? render : zero(render)
end

"""
    surface_discrepancy(depth_context, estimate, ground_truth, τ)
Calculate the surface discrepancy according to [BOP19](https://bop.felk.cvut.cz/challenges/bop-challenge-2019/) by rendering two scenes.
τ is the misalignment tolerance, for the VSD, the images must have been masked.
"""
function surface_discrepancy(depth_context::OffscreenContext, estimate::Scene, ground_truth::Scene, τ)
    es_img, gt_img = draw_distance(depth_context, estimate, ground_truth)
    surface_discrepancy(es_img, gt_img, τ)
end

"""
    surface_discrepancy(estimate, ground_truth, τ)
Calculate the surface discrepancy according to [BOP19](https://bop.felk.cvut.cz/challenges/bop-challenge-2019/) for two rendered distance images.
τ is the misalignment tolerance.
For the calculation of the VSD, the images must have been masked.
"""
function surface_discrepancy(estimate::AbstractArray{T}, ground_truth::AbstractArray{U}, τ::V) where {T,U,V}
    union_count = sum(@. estimate > 0 || ground_truth > 0)
    # early stopping and no division by zero
    if iszero(union_count)
        return one(promote(T, U, V))
    end
    costs = discrepancy_cost.(estimate, ground_truth, τ)
    # Average of the costs for the union pixels
    sum(costs) / union_count
end

"""
    discrepancy_cost(dist_a, dist_b, τ)
Step function costs according to [BOP19](https://bop.felk.cvut.cz/challenges/bop-challenge-2019/).
Returns true (1) adding cost and false (0) for no cost
"""
function discrepancy_cost(dist_a, dist_b, τ)
    a_valid, b_valid = (dist_a, dist_b) .> 0
    if !a_valid && !b_valid
        # Do not add any cost if not part of union
        return false
    elseif a_valid ⊻ b_valid
        # Not part of intersection -> always cost
        return true
    else
        # Part of intersection. Cost if misalignment tolerance is violated
        return abs(dist_b - dist_a) > τ
    end
end

"""
    draw_distance(depth_context, estimate, ground_truth)
Returns a tuple of the depth images for the estimate and ground truth.
"""
function draw_distance(distance_context::OffscreenContext, estimate::Scene, ground_truth::Scene)
    if last(size(distance_context)) > 1
        imgs = draw(distance_context, [estimate, ground_truth])
        es_img = @view(imgs[:, :, 1])
        gt_img = @view(imgs[:, :, 2])
    else
        # Buffer is overwritten → copy it
        es_img = copy(draw(distance_context, estimate))
        gt_img = draw(distance_context, ground_truth)
    end
    es_img, gt_img
end

# Performance Scores
"""
    pdm_avg_recall(diameter. distances, [thresholds=0.05:0.05:0.5])
The fraction of annotated object instances, for which a correct pose is estimated, is referred to as recall. 
Poses are considered correct for `distance < threshold * diameter`.
"""
pdm_avg_recall(diameter, distances, thresholds=0.05:0.05:0.5) = pdm_correct(diameter, distances, thresholds) |> mean
pdm_correct(diameters, distances, thresholds=5e-2:5e-2:50e-2) = [e < θ * diameters for e in distances, θ in thresholds]

"""
    vsd_avg_recall(discrepancies, [thresholds=0.05:0.05:0.5])
The fraction of annotated object instances, for which a correct pose is estimated, is referred to as recall. 
Poses are considered correct for `discrepancy < threshold`.
"""
vsd_avg_recall(discrepancies, thresholds=0.05:0.05:0.5) = vsd_correct(discrepancies, thresholds) |> mean
vsd_correct(discrepancies, thresholds=0.05:0.05:0.5) = [e < θ for e in discrepancies, θ in thresholds]

end # module PoseErrors
