/*
 * Copyright (C) 2016-2018, Nils Moehrle
 * All rights reserved.
 *
 * This software may be modified and distributed under the terms
 * of the BSD 3-Clause license. See the LICENSE.txt file for details.
 */

#include <cassert>
#include <iostream>

#if 0
#include "fmt/format.h"
#endif

#include "util/system.h"
#include "util/arguments.h"
#include "util/file_system.h"

#include "mve/camera.h"
#include "mve/mesh_io_ply.h"
#include "mve/image_io.h"
#include "mve/image_tools.h"

#include "acc/primitives.h"

#include "cacc/math.h"
#include "cacc/util.h"
#include "cacc/bvh_tree.h"
#include "cacc/nnsearch.h"
#include "cacc/point_cloud.h"

#include "util/io.h"
#include "util/cio.h"
#include "util/progress_counter.h"
#include "util/itos.h"

#include "geom/sphere.h"
#include "geom/volume_io.h"

#include "eval/kernels.h"

constexpr float lowest = std::numeric_limits<float>::lowest();

struct Arguments {
    std::string proxy_mesh;
    std::string proxy_cloud;
    std::string airspace_mesh;
    std::string ovolume;
    float resolution;
    float max_distance;
    float min_altitude;
    float max_altitude;
};

Arguments parse_args(int argc, char **argv) {
    util::Arguments args;
    args.set_exit_on_error(true);
    args.set_nonopt_minnum(4);
    args.set_nonopt_maxnum(4);
    args.set_usage("Usage: " + std::string(argv[0]) + " [OPTS] PROXY_MESH PROXY_CLOUD AIRSPACE_MESH OUT_VOLUME");
    args.set_description("TODO");
    args.add_option('r', "resolution", true, "guidance volume resolution [1.0]");
    args.add_option('\0', "max-distance", true, "maximum distance to surface [80.0]");
    args.add_option('\0', "min-altitude", true, "minimum altitude [0.0]");
    args.add_option('\0', "max-altitude", true, "maximum altitude [100.0]");
    args.parse(argc, argv);

    Arguments conf;
    conf.proxy_mesh = args.get_nth_nonopt(0);
    conf.proxy_cloud = args.get_nth_nonopt(1);
    conf.airspace_mesh = args.get_nth_nonopt(2);
    conf.ovolume = args.get_nth_nonopt(3);
    conf.resolution = 1.0f;
    conf.max_distance = 80.0f;
    conf.min_altitude = 0.0f;
    conf.max_altitude = 100.0f;

    for (util::ArgResult const* i = args.next_option();
         i != 0; i = args.next_option()) {
        switch (i->opt->sopt) {
        case 'r':
            conf.resolution = i->get_arg<float>();
        break;
        case '\0':
            if (i->opt->lopt == "max-distance") {
                conf.max_distance = i->get_arg<float>();
            } else if (i->opt->lopt == "min-altitude") {
                conf.min_altitude = i->get_arg<float>();
            } else if (i->opt->lopt == "max-altitude") {
                conf.max_altitude = i->get_arg<float>();
            } else {
                throw std::invalid_argument("Invalid option");
            }
        break;
        default:
            throw std::invalid_argument("Invalid option");
        }
    }

    return conf;
}

int main(int argc, char **argv) {
    util::system::register_segfault_handler();
    util::system::print_build_timestamp(argv[0]);

    Arguments args = parse_args(argc, argv);

    int device = cacc::select_cuda_device(3, 5);

    cacc::BVHTree<cacc::DEVICE>::Ptr dbvh_tree;
    {
        acc::BVHTree<uint, math::Vec3f>::Ptr bvh_tree;
        bvh_tree = load_mesh_as_bvh_tree(args.proxy_mesh);
        dbvh_tree = cacc::BVHTree<cacc::DEVICE>::create<uint, math::Vec3f>(bvh_tree);
    }

    mve::TriangleMesh::Ptr mesh;
    try {
        mesh = mve::geom::load_ply_mesh(args.airspace_mesh);
    } catch (std::exception& e) {
        std::cerr << "\tCould not load mesh: " << e.what() << std::endl;
        std::exit(EXIT_FAILURE);
    }

    std::vector<math::Vec3f> const & verts = mesh->get_vertices();

    //TODO merge with proxy mesh generation code
    acc::AABB<math::Vec3f> aabb = acc::calculate_aabb(verts);

    assert(acc::valid(aabb) && acc::volume(aabb) > 0.0f);

    int width = (aabb.max[0] - aabb.min[0]) / args.resolution + 1.0f;
    int height = (aabb.max[1] - aabb.min[1]) / args.resolution + 1.0f;
    int depth = args.max_altitude / args.resolution + 1.0f;

    std::cout << width << "x" << height << "x" << depth << std::endl;

    /* Create height map. */
    mve::FloatImage::Ptr hmap = mve::FloatImage::create(width, height, 1);
    hmap->fill(lowest);
    for (std::size_t i = 0; i < verts.size(); ++i) {
        math::Vec3f vertex = verts[i];
        int x = (vertex[0] - aabb.min[0]) / args.resolution;
        assert(0 <= x && x < width);
        int y = (vertex[1] - aabb.min[1]) / args.resolution;
        assert(0 <= y && y < height);
        float height = vertex[2];
        float z = hmap->at(x, y, 0);
        if (z > height) continue;

        hmap->at(x, y, 0) = height;
    }

    /* Estimate ground level and normalize height map */
    float ground_level = std::numeric_limits<float>::max();
    #pragma omp parallel for reduction(min:ground_level)
    for (int i = 0; i < hmap->get_value_amount(); ++i) {
        float height = hmap->at(i);
        if (height != lowest && height < ground_level) {
            ground_level = height;
        }
    }

    #pragma omp parallel for
    for (int i = 0; i < hmap->get_value_amount(); ++i) {
        float height = hmap->at(i);
        hmap->at(i) = (height != lowest) ? height - ground_level : 0.0f;
    }
    //ODOT merge with proxy mesh generation code

    Volume<std::uint32_t>::Ptr volume;
    volume = Volume<std::uint32_t>::create(width, height, depth, aabb.min, aabb.max);
    std::vector<math::Vector<std::uint32_t, 3> > sample_positions;
    sample_positions.reserve(volume->num_positions());

    for (int y = 0; y < height; ++y) {
        for (int x = 0; x < width; ++x) {

            float px = (x - args.resolution / 2.0f) * args.resolution + aabb.min[0];
            float py = (y - args.resolution / 2.0f) * args.resolution + aabb.min[1];

            float fz = std::max(hmap->at(x, y, 0), args.min_altitude);

            for (int z = 0; z < depth; ++z) {
                float pz = ground_level + z * args.resolution;

                if (pz < fz) continue;

                sample_positions.emplace_back(x, y, z);
            }
        }
    }

    uint num_verts;
    cacc::KDTree<3u, cacc::DEVICE>::Ptr dkd_tree;
    {
        mve::TriangleMesh::Ptr sphere = generate_sphere_mesh(1.0f, 3u);
        std::vector<math::Vec3f> const & verts = sphere->get_vertices();
        num_verts = verts.size();
        acc::KDTree<3u, uint>::Ptr kd_tree = acc::KDTree<3, uint>::create(verts);
        dkd_tree = cacc::KDTree<3u, cacc::DEVICE>::create<uint>(kd_tree);
    }

    cacc::PointCloud<cacc::DEVICE>::Ptr dcloud;
    {
        cacc::PointCloud<cacc::HOST>::Ptr cloud;
        cloud = load_point_cloud(args.proxy_cloud);
        dcloud = cacc::PointCloud<cacc::DEVICE>::create<cacc::HOST>(cloud);
    }

    mve::CameraInfo cam;
    cam.flen = 0.86f;
    math::Matrix3f calib;

    std::size_t num_samples = sample_positions.size() * 128ull * 45ull;

#if 0
    std::string task = fmt::format("Sampling 5D volume at {} positions", litos(num_samples));
#else
    std::string task("Sampling 5D volume at ");
    task += litos(num_samples);
    task += std::string(" positions");
#endif
    ProgressCounter counter(task, sample_positions.size());

    #pragma omp parallel
    {
        cacc::set_cuda_device(device);

        cudaStream_t stream;
        cudaStreamCreate(&stream);

        int width = 1920;
        int height = 1080;
        cam.fill_calibration(calib.begin(), width, height);

        cacc::Array<float, cacc::DEVICE>::Ptr dobs_hist;
        dobs_hist = cacc::Array<float, cacc::DEVICE>::create(num_verts, stream);

        cacc::Image<float, cacc::DEVICE>::Ptr dhist;
        dhist = cacc::Image<float, cacc::DEVICE>::create(128, 45, stream);
        cacc::Image<float, cacc::HOST>::Ptr hist;
        hist = cacc::Image<float, cacc::HOST>::create(128, 45, stream);

        #pragma omp for schedule(dynamic)
        for (std::size_t i = 0; i < sample_positions.size(); ++i) {
            counter.progress<ETA>();

            dobs_hist->null();
            {
                dim3 grid(cacc::divup(dcloud->cdata().num_vertices, KERNEL_BLOCK_SIZE));
                dim3 block(KERNEL_BLOCK_SIZE);
                populate_spherical_histogram<<<grid, block, 0, stream>>>(
                    cacc::Vec3f(volume->position(sample_positions[i]).begin()),
                    args.max_distance, dbvh_tree->accessor(), dcloud->cdata(),
                    dkd_tree->accessor(), dobs_hist->cdata());
            }

            {
                dim3 grid(cacc::divup(128, KERNEL_BLOCK_SIZE), 45);
                dim3 block(KERNEL_BLOCK_SIZE);
                evaluate_spherical_histogram<<<grid, block, 0, stream>>>(
                    cacc::Mat3f(calib.begin()), width, height,
                    dkd_tree->accessor(), dobs_hist->cdata(), dhist->cdata());
            }

            *hist = *dhist;
            cacc::Image<float, cacc::HOST>::Data data = hist->cdata();

            hist->sync();

            mve::FloatImage::Ptr image = mve::FloatImage::create(128, 45, 1);
            float const * begin = data.data_ptr;
            float const * end = data.data_ptr + data.width * data.height;
            std::copy(begin, end, image->get_data_pointer());
            volume->at(sample_positions[i]) = image;

            counter.inc();
        }
        cudaStreamDestroy(stream);
    }

    save_volume<std::uint32_t>(volume, args.ovolume);

    return EXIT_SUCCESS;
}
