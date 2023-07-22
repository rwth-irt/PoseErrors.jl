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
    image_dataframe(scene_path)
Load the image information as a DataFrame with the columns `img_id, depth_path, color_path, img_size` with `img_size=(width, height)`.
`color_path` either contains rgb or grayscale images.
"""
function image_dataframe(scene_path)
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
    DataFrame(img_id=img_ids, depth_path=depth_paths, color_path=color_paths, img_size=img_sizes)
end

"""
    camera_dataframe(scene_path, img_df)
Load the camera information as a DataFrame with the columns `img_id, camera, depth_scale`.
`img_df` is the DataFrame generated by `image_dataframe` for the same `scene_path`.
"""
function camera_dataframe(scene_path, img_df)
    img_sizes = Dict(img_df.img_id .=> img_df.img_size)
    json_cams = JSON.parsefile(joinpath(scene_path, "scene_camera.json"))
    img_ids = parse.(Int, keys(json_cams))
    df = DataFrame(img_id=Int[], cv_camera=CvCamera[], depth_scale=Float32[])
    for img_id in img_ids
        width, height = img_sizes[img_id]
        json_cam = json_cams[string(img_id)]
        cam_K = json_cam["cam_K"] .|> Float32
        cv_cam = CvCamera(width, height, cam_K[1], cam_K[5], cam_K[3], cam_K[6]; s=cam_K[4])
        scale = json_cam["depth_scale"] .|> Float32
        push!(df, (img_id, cv_cam, scale))
    end
    df
end

"""
    gt_dataframe(scene_path)
Load the ground truth information for each object and image as a DataFrame with the columns `img_id, obj_id, cam_R_m2c, cam_t_m2c, mask_path, mask_visib_path`.
"""
function gt_dataframe(scene_path)
    gt_json = JSON.parsefile(joinpath(scene_path, "scene_gt.json"))
    df = DataFrame(img_id=Int[], obj_id=Int[], gt_id=Int[], cam_R_m2c=QuatRotation[], cam_t_m2c=Vector{Float32}[], mask_path=String[], mask_visib_path=String[])
    for (img_id, body) in gt_json
        img_id = parse(Int, img_id)
        for (gt_id, gt) in enumerate(body)
            obj_id = gt["obj_id"]
            # Saved row-wise, Julia is column major
            cam_R_m2c = reshape(gt["cam_R_m2c"], 3, 3)' |> RotMatrix3 |> QuatRotation
            cam_t_m2c = Float32.(1e-3 * gt["cam_t_m2c"])
            # masks paths (mind julia vs python indexing)
            mask_filename = lpad_bop(img_id) * "_" * lpad_bop(gt_id - 1) * ".png"
            mask_path = joinpath(scene_path, "mask", mask_filename)
            mask_visib_path = joinpath(scene_path, "mask_visib", mask_filename)
            push!(df, (img_id, obj_id, gt_id, cam_R_m2c, cam_t_m2c, mask_path, mask_visib_path))
        end
    end
    df
end

function gt_info_dataframe(scene_path; visib_threshold=0.1)
    gt_info_json = JSON.parsefile(joinpath(scene_path, "scene_gt_info.json"))
    df = DataFrame(img_id=Int[], gt_id=Int[], visib_fract=Float32[])
    for (img_id, body) in gt_info_json
        img_id = parse(Int, img_id)
        for (gt_id, gt_info) in enumerate(body)
            visib_fract = gt_info["visib_fract"]
            if (visib_fract >= visib_threshold)
                push!(df, (img_id, gt_id, visib_fract))
            end
        end
    end
    df
end

"""
    object_dataframe(dataset_path)
Loads the object specific information into a DataFrame with the columns `obj_id, diameter, mesh`.
"""
function object_dataframe(dataset_path)
    json = JSON.parsefile(joinpath(dataset_path, "models_eval", "models_info.json"))
    df = DataFrame(obj_id=Int[], diameter=Float32[], mesh_path=String[])
    for (obj_id, data) in json
        obj_id = parse(Int, obj_id)
        diameter = Float32(1e-3 .* data["diameter"])
        filename = "obj_" * lpad_bop(obj_id) * ".ply"
        mesh_path = joinpath(dataset_path, "models_eval", filename)
        push!(df, (obj_id, diameter, mesh_path))
    end
    df
end

"""
    scene_dataframe(datasubset_path, scene_number)
Loads the information of a single scene into a DataFrame by combining the image, object and gt information into a single DataFrame`.
"""
function scene_dataframe(datasubset_path, scene_id=1)
    # TODO allow custom root dir
    path = bop_scene_path(datasubset_path, scene_id)
    # Per image
    img_df = image_dataframe(path)
    img_df[!, :scene_id] .= scene_id
    cam_df = camera_dataframe(path, img_df)
    img_cam_df = innerjoin(img_df, cam_df; on=:img_id)
    # Per evaluation
    gt_df = gt_dataframe(path)
    info_df = gt_info_dataframe(path)
    # only visib_fract >= 0.1 is considered valid → gt_info_df might include less entries on purpose
    gt_info_df = rightjoin(gt_df, info_df; on=[:img_id, :gt_id])
    gt_img_df = leftjoin(gt_info_df, img_cam_df, on=:img_id)
    # Per object
    obj_df = object_dataframe(dirname(datasubset_path))
    leftjoin(gt_img_df, obj_df, on=:obj_id)
end

"""
    crop_boundingbox(df_row)
Get the bounding box of the object & pose in the DataFrameRow.
"""
crop_boundingbox(df_row::DataFrameRow) = crop_boundingbox(df_row.cv_camera, df_row.cam_t_m2c, df_row.diameter)

"""
    crop_camera(df_row)
Get the cropped camera for the bounding box of the object & pose in the DataFrameRow.
"""
crop_camera(df_row::DataFrameRow) = crop(df_row.cv_camera, crop_boundingbox(df_row)...)

"""
    load_image(path, df_row, width, height)
Load an image in OpenGL convention: (x,y) coordinates instead of Julia images (y,x) convention.
"""
function load_image(path, df_row, width, height)
    bounding_box = crop_boundingbox(df_row)
    image = path |> load |> transpose
    crop_image(image, bounding_box..., width, height)
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
Load the gt mask image which includes the occluded parts, crop it, and resize it to (width, height).
See also [load_visib_mask_image](@ref)
"""
load_mask_image(df_row, width, height) = load_image(df_row.mask_path, df_row, width, height) .|> Bool

"""
   load_visib_mask_image(df_row, width, height)
Load the gt mask image which only covers the visible parts, crop it, and resize it to (width, height).
See also [load_mask_image](@ref)
"""
load_visib_mask_image(df_row, width, height) = load_image(df_row.mask_visib_path, df_row, width, height) .|> Bool

"""
   load_mesh(df_row, width, height)
Load the mesh file from the disk and scale it to meters.
"""
load_mesh(df_row) = Scale(Float32(1e-3))(load(df_row.mesh_path))

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
