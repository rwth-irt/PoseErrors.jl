# @license BSD-3 https://opensource.org/licenses/BSD-3-Clause
# Copyright (c) 2023, Institute of Automatic Control - RWTH Aachen University
# All rights reserved. 

using Base.Filesystem
using DataFrames
using FileIO
using ImageCore
using ImageIO
using JSON
using SciGL
using StaticArrays

# TODO output poses in BOP evaluation format. Output sampler diagnostics in separate file.
# TODO load this file in PoseErrors.jl (new BOP.jl file there) and save the errors in a new file. Finally calculate recall, plot error histograms, recall/threshold curve.

"""
    bop_scene_ids(datasubset_path)
Returns a vector of integers for the scene ids in the dataset which can be used in [`bop_scene_path`](@ref).
"""
function bop_scene_ids(datasubset_path)
    dirs = readdir(datasubset_path; join=true)
    @. parse(Int, basename(dirs))
end

"""
    lpad_bop(number)
Pads the number with zeros from the left for a total length of six digits.
`pad_bop(42) = 000042`
"""
lpad_bop(number) = lpad(number, 6, "0")

"""
    bop_scene_ids(scene_id, root_dir..., dataset_name, subset_name)
Returns the path to the scene directory with the given number of the datasets subset.
e.g. 'tless/test_primesense/000001'
"""
bop_scene_path(datasubset_path, scene_id) = joinpath(datasubset_path, lpad_bop(scene_id))

"""
    image_dataframe(datasubset_path, scene_id)
Load the image information as a DataFrame with the columns `scene_id, img_id, depth_path, color_path, img_size` with `img_size=(width, height)`.
`color_path` either contains rgb or grayscale images.
"""
function image_dataframe(datasubset_path, scene_id)
    scene_path = bop_scene_path(datasubset_path, scene_id)
    depth_dir = joinpath(scene_path, "depth")
    rgb_dir = joinpath(scene_path, "rgb")
    gray_dir = joinpath(scene_path, "gray")
    depth_paths = readdir(depth_dir; join=true)
    # Depending on the dataset either gray or rgb is available
    color_paths = isdir(rgb_dir) ? readdir(rgb_dir; join=true) : readdir(gray_dir; join=true)
    img_ids = @. parse(Int, depth_paths |> splitext |> first |> splitpath |> last)
    img_sizes = map(depth_paths) do img_path
        # ImageIO loads transposed
        img = img_path |> load |> transpose
        size(img)
    end
    DataFrame(scene_id=fill(scene_id, length(img_ids)), img_id=img_ids, depth_path=depth_paths, color_path=color_paths, img_size=img_sizes)
end

"""
    camera_dataframe(scene_path, scene_id, img_df)
Load the camera information as a DataFrame with the columns `scene_id, img_id, camera, depth_scale`.
`img_df` is the DataFrame generated by `image_dataframe` for the same `scene_path`.
"""
function camera_dataframe(datasubset_path, scene_id, img_df)
    scene_path = bop_scene_path(datasubset_path, scene_id)
    img_sizes = Dict(img_df.img_id .=> img_df.img_size)
    json_cams = JSON.parsefile(joinpath(scene_path, "scene_camera.json"))
    img_ids = parse.(Int, keys(json_cams))
    df = DataFrame(scene_id=Int[], img_id=Int[], cv_camera=CvCamera[], depth_scale=Float32[])
    for img_id in img_ids
        width, height = img_sizes[img_id]
        json_cam = json_cams[string(img_id)]
        cam_K = json_cam["cam_K"] .|> Float32
        cv_cam = CvCamera(width, height, cam_K[1], cam_K[5], cam_K[3], cam_K[6]; s=cam_K[4])
        scale = json_cam["depth_scale"] .|> Float32
        push!(df, (scene_id, img_id, cv_cam, scale))
    end
    df
end

"""
    gt_dataframe(datasubset_path, scene_id)
Load the ground truth information for each object and image as a DataFrame with the columns `scene_id, img_id, obj_id, gt_R, gt_t, mask_path, mask_visib_path`.
"""
function gt_dataframe(datasubset_path, scene_id)
    scene_path = bop_scene_path(datasubset_path, scene_id)
    gt_json = JSON.parsefile(joinpath(scene_path, "scene_gt.json"))
    df = DataFrame(scene_id=Int[], img_id=Int[], obj_id=Int[], gt_id=Int[], gt_R=QuatRotation[], gt_t=Vector{Float32}[], mask_path=String[], mask_visib_path=String[])
    for (img_id, body) in gt_json
        img_id = parse(Int, img_id)
        for (gt_id, gt) in enumerate(body)
            obj_id = gt["obj_id"]
            # Saved row-wise, Julia is column major
            gt_R = reshape(gt["cam_R_m2c"], 3, 3)' |> RotMatrix3 |> QuatRotation
            gt_t = Float32.(1e-3 * gt["cam_t_m2c"])
            # masks paths (mind julia vs python indexing)
            mask_filename = lpad_bop(img_id) * "_" * lpad_bop(gt_id - 1) * ".png"
            mask_path = joinpath(scene_path, "mask", mask_filename)
            mask_visib_path = joinpath(scene_path, "mask_visib", mask_filename)
            push!(df, (scene_id, img_id, obj_id, gt_id, gt_R, gt_t, mask_path, mask_visib_path))
        end
    end
    df
end

"""
    gt_info_dataframe(datasubset_path, scene_id; [visib_threshold])
Parse the *scene_gt_info.json* into a DataFrame with columns `scene_id, img_id, gt_id, visib_fract, bbox`.
By default object where less than 10% of the surface are visible are excluded.
"""
function gt_info_dataframe(datasubset_path, scene_id; visib_threshold=0.1)
    scene_path = bop_scene_path(datasubset_path, scene_id)
    gt_info_json = JSON.parsefile(joinpath(scene_path, "scene_gt_info.json"))
    df = DataFrame(scene_id=Int[], img_id=Int[], gt_id=Int[], visib_fract=Float32[], bbox=NTuple{4,Int}[])
    for (img_id, body) in gt_info_json
        img_id = parse(Int, img_id)
        for (gt_id, gt_info) in enumerate(body)
            visib_fract = gt_info["visib_fract"]
            if (visib_fract >= visib_threshold)
                x, y, width, height = gt_info["bbox_visib"]
                left, right = x, x + width
                top, bottom = y, y + height
                # julia convention: start at 1
                bbox_visib = (left, right, top, bottom) .+ 1
                push!(df, (scene_id, img_id, gt_id, visib_fract, bbox_visib))
            end
        end
    end
    df
end

"""
    object_dataframe(dataset_path)
Loads the object specific information into a DataFrame with the columns `obj_id, diameter, mesh_path, mesh_eval_path`.
If CAD exists, `mesh_path` points to it. Otherwise the reconstructed mesh is used
"""
function object_dataframe(dataset_path)
    # If CAD exists use it otherwise the reconstructed one
    models_path = isdir(joinpath(dataset_path, "models_cad")) ? joinpath(dataset_path, "models_cad") : joinpath(dataset_path, "models")
    json = JSON.parsefile(joinpath(models_path, "models_info.json"))
    df = DataFrame(obj_id=Int[], diameter=Float32[], mesh_path=String[], mesh_eval_path=String[])
    for (obj_id, data) in json
        obj_id = parse(Int, obj_id)
        diameter = Float32(1e-3 .* data["diameter"])
        filename = "obj_" * lpad_bop(obj_id) * ".ply"
        mesh_path = joinpath(models_path, filename)
        mesh_eval_path = joinpath(dataset_path, "models_eval", filename)
        push!(df, (obj_id, diameter, mesh_path, mesh_eval_path))
    end
    df
end

"""
    center_diameter_boundingbox(df_row)
Get the bounding box of the object & pose in the DataFrameRow.
"""
center_diameter_boundingbox(df_row::DataFrameRow) = center_diameter_boundingbox(df_row.cv_camera, df_row.cam_t_m2c, df_row.diameter)

"""
    crop_camera(df_row)
Get the cropped camera for the bounding box of the object & pose in the DataFrameRow.
"""
crop_camera(df_row::DataFrameRow) = crop(df_row.cv_camera, df_row.bbox...)

"""
    load_image(path, df_row, width, height)
Load an image in OpenGL convention: (x,y) coordinates instead of Julia images (y,x) convention.
"""
function load_image(path, df_row, width, height)
    image = path |> load |> transpose
    crop_image(image, df_row.bbox..., width, height)
end

load_depth_image(path, df_row, width, height) = (load_image(path, df_row, width, height) |> channelview |> rawview) .* Float32(1e-3 * df_row.depth_scale)
"""
    load_depth_image(df_row)
Load the depth image as a Matrix{Float32}, crop it, and resize it to (width, height) where each pixel is the depth in meters.
"""
load_depth_image(df_row, width, height) = load_depth_image(df_row.depth_path, df_row, width, height)

"""
   load_color_image(df_row, width, height)
Load the color image, crop it, and resize it to (width, height).
"""
load_color_image(df_row, width, height) = load_image(df_row.color_path, df_row, width, height)

"""
   load_mask_image(df_row, width, height)
Load the mask image which includes only the visible parts, crop it, and resize it to (width, height).
See also [load_visib_mask_image](@ref)
"""
load_mask_image(df_row, width, height) = load_image(df_row.mask_visib_path, df_row, width, height) .|> Bool

"""
   load_mesh(df_row)
Load the mesh file from the disk and scale it to meters.
"""
load_mesh(df_row) = Scale(Float32(1e-3))(load(df_row.mesh_path))

"""
   load_mesh_eval(df_row)
Load the evaluation mesh file from the disk and scale it to meters.
Use it only for point distance metrics like ADDS or MDDS.
"""
load_mesh_eval(df_row) = Scale(Float32(1e-3))(load(df_row.mesh_eval_path))

"""
   load_segmentation(df_row, width, height)
Load the segmentation mask, crop it, and resize it to (width, height).
See also [load_visib_mask_image](@ref)
"""
function load_segmentation(df_row, width, height)
    mask_img = load_segmentation(df_row)
    crop_image(transpose(mask_img), df_row.bbox..., width, height) .|> Bool
end

"""
    load_segmentation(df_row)
Load the estimated segmentation by converting the rdf mask to a binary mask.
"""
load_segmentation(df_row) = rdf_to_binary_mask(df_row.segmentation)

function rdf_to_binary_mask(segmentation)
    seg_counts = segmentation.counts
    seg_size = segmentation.size
    seg_img = Array{Bool}(undef, seg_size...)
    is_mask = false
    c_sum = 1
    for c in seg_counts
        seg_img[c_sum:c_sum+c-1] .= is_mask
        c_sum += c
        is_mask = !is_mask
    end
    seg_img
end
