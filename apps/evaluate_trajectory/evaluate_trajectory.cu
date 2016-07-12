#include <chrono>
#include <atomic>
#include <iostream>

#include <cuda_runtime.h>

#include "util/arguments.h"

#include "mve/mesh_io_ply.h"
#include "mve/scene.h"

#include "acc/bvh_tree.h"

#include "cacc/point_cloud.h"
#include "cacc/util.h"
#include "cacc/matrix.h"
#include "cacc/bvh_tree.h"
#include "cacc/tracing.h"

#include "col/mpl_viridis.h"

#include "kernels.h"

typedef unsigned char uchar;

#define GPU 1

inline
uint divup(uint a, uint b) {
    return a / b  + (a % b != 0);
}

cacc::PointCloud<cacc::HOST>::Ptr
load_point_cloud(std::string const & path)
{
    mve::TriangleMesh::Ptr mesh;
    try {
        mesh = mve::geom::load_ply_mesh(path);
    } catch (std::exception& e) {
        std::cerr << "\tCould not load mesh: " << e.what() << std::endl;
        std::exit(EXIT_FAILURE);
    }
    mesh->ensure_normals(true, true);

    std::vector<math::Vec3f> const & vertices = mesh->get_vertices();
    std::vector<math::Vec3f> const & normals = mesh->get_vertex_normals();

    cacc::PointCloud<cacc::HOST>::Ptr ret;
    ret = cacc::PointCloud<cacc::HOST>::create(vertices.size());
    cacc::PointCloud<cacc::HOST>::Data data = ret->cdata();
    for (std::size_t i = 0; i < vertices.size(); ++i) {
        data.vertices_ptr[i] = cacc::Vec3f(vertices[i].begin());
        data.normals_ptr[i] = cacc::Vec3f(normals[i].begin());
    }

    return ret;
}

acc::BVHTree<uint, math::Vec3f>::Ptr
load_mesh_as_bvh_tree(std::string const & path)
{
    mve::TriangleMesh::Ptr mesh;
    try {
        mesh = mve::geom::load_ply_mesh(path);
    } catch (std::exception& e) {
        std::cerr << "\tCould not load mesh: "<< e.what() << std::endl;
        std::exit(EXIT_FAILURE);
    }

    std::vector<math::Vec3f> const & vertices = mesh->get_vertices();
    std::vector<uint> const & faces = mesh->get_faces();
    return acc::BVHTree<uint, math::Vec3f>::create(faces, vertices);
}

void load_scene_as_trajectory(std::string const & path, std::vector<mve::CameraInfo> * trajectory) {
    mve::Scene::Ptr scene;
    try {
        scene = mve::Scene::create(path);
    } catch (std::exception& e) {
        std::cerr << "Could not open scene: " << e.what() << std::endl;
        std::exit(EXIT_FAILURE);
    }

    for (mve::View::Ptr const & view : scene->get_views()) {
        if (view == nullptr) continue;
        trajectory->push_back(view->get_camera());
    }
}

struct Arguments {
    std::string scene;
    std::string proxy_mesh;
    std::string proxy_cloud;
    std::string export_cloud;
};

Arguments parse_args(int argc, char **argv) {
    util::Arguments args;
    args.set_exit_on_error(true);
    args.set_nonopt_maxnum(3);
    args.set_nonopt_minnum(3);
    args.set_usage("Usage: " + std::string(argv[0]) + " [OPTS] SCENE PROXY_MESH PROXY_CLOUD");
    args.add_option('e', "export", true, "export per surface point reconstructability as point cloud");
    args.set_description("Evaluate trajectory");
    args.parse(argc, argv);

    Arguments conf;
    conf.scene = args.get_nth_nonopt(0);
    conf.proxy_mesh = args.get_nth_nonopt(1);
    conf.proxy_cloud = args.get_nth_nonopt(2);

    for (util::ArgResult const* i = args.next_option();
         i != nullptr; i = args.next_option()) {
        switch (i->opt->sopt) {
        case 'e':
            conf.export_cloud = i->arg;
        break;
        default:
            throw std::invalid_argument("Invalid option");
        }
    }

    return conf;
}

int main(int argc, char * argv[])
{
    Arguments args = parse_args(argc, argv);

    cacc::select_cuda_device(3, 5);

    acc::BVHTree<uint, math::Vec3f>::Ptr bvh_tree;
    bvh_tree = load_mesh_as_bvh_tree(args.proxy_mesh);
    cacc::BVHTree<cacc::DEVICE>::Ptr dbvh_tree;
    dbvh_tree = cacc::BVHTree<cacc::DEVICE>::create<uint, math::Vec3f>(bvh_tree);
    cacc::tracing::bind_textures(dbvh_tree->cdata());

    cacc::PointCloud<cacc::HOST>::Ptr cloud;
    cloud = load_point_cloud(args.proxy_cloud);
    cacc::PointCloud<cacc::DEVICE>::Ptr dcloud;
    dcloud = cacc::PointCloud<cacc::DEVICE>::create<cacc::HOST>(cloud);

    uint num_vertices = dcloud->cdata().num_vertices;
    uint max_cameras = 20;

    cacc::VectorArray<cacc::HOST, cacc::Vec2f>::Ptr hdir_hist;
    hdir_hist = cacc::VectorArray<cacc::HOST, cacc::Vec2f>::create(num_vertices, max_cameras);
    cacc::VectorArray<cacc::DEVICE, cacc::Vec2f>::Ptr ddir_hist;
    ddir_hist = cacc::VectorArray<cacc::DEVICE, cacc::Vec2f>::create(num_vertices, max_cameras);

    std::vector<mve::CameraInfo> trajectory;
    load_scene_as_trajectory(args.scene, &trajectory);

    int width = 1920;
    int height = 1080;
    math::Matrix4f w2c;
    math::Matrix3f calib;
    math::Vec3f view_pos(0.0f);

    std::chrono::time_point<std::chrono::high_resolution_clock> start, end;

#if CPU
    start = std::chrono::high_resolution_clock::now();
    #pragma omp parallel
    {
        cacc::VectorArray<cacc::HOST, cacc::Vec2f>::Data const & dir_hist = hdir_hist->cdata();
        for (mve::CameraInfo const & cam : trajectory) {
            cam.fill_calibration(calib.begin(), width, height);
            cam.fill_world_to_cam(w2c.begin());
            cam.fill_camera_pos(view_pos.begin());

            #pragma omp for
            for (std::size_t i = 0; i < cloud->cdata().num_vertices; ++i) {
                cacc::Vec3f const & cv = cloud->cdata().vertices_ptr[i];
                math::Vec3f v; //TODO fix this mess
                for (int j = 0; j < 3; ++j) v[j] = cv[j];

                math::Vec3f v2c = view_pos - v;
                float n = v2c.norm();
                //if (n > 80.0f) continue;
                math::Vec3f pt = calib * w2c.mult(v, 1.0f);
                math::Vec2f p(pt[0] / pt[2] - 0.5f, pt[1] / pt[2] - 0.5f);

                if (p[0] < 0.0f || width <= p[0] || p[1] < 0.0f || height <= p[1]) continue;

                acc::Ray<math::Vec3f> ray;
                ray.origin = v + v2c * 0.01f;
                ray.dir = v2c / n;
                ray.tmin = 0.0f;
                ray.tmax = inf;

                if (bvh_tree->intersect(ray)) continue;

                uint row = dir_hist.num_rows_ptr[i];
                if (row >= dir_hist.max_rows) continue;

                dir_hist.num_rows_ptr[i] = row;
                cacc::Vec2f dir(atan2(ray.dir[1], ray.dir[0]), acos(ray.dir[2]));
                int const stride = dir_hist.pitch / sizeof(cacc::Vec2f
                dir_hist.data_ptr[row * stride + i] = dir;

                dir_hist.num_rows_ptr[i] += 1;
            }

        }
    }
    end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> diff = end - start;
    std::cout << "CPU: " << diff.count() << std::endl;
#endif

#if GPU
    start = std::chrono::high_resolution_clock::now();
    {
        cudaStream_t stream;
        cudaStreamCreate(&stream);
        dim3 grid(divup(dcloud->cdata().num_vertices, KERNEL_BLOCK_SIZE));
        dim3 block(KERNEL_BLOCK_SIZE);

        for (mve::CameraInfo const & cam : trajectory) {
            cam.fill_calibration(calib.begin(), width, height);
            cam.fill_world_to_cam(w2c.begin());
            cam.fill_camera_pos(view_pos.begin());

            populate_histogram<<<grid, block, 0, stream>>>(
                cacc::Mat4f(w2c.begin()), cacc::Mat3f(calib.begin()),
                cacc::Vec3f(view_pos.begin()), width, height,
                dbvh_tree->cdata(), dcloud->cdata(), ddir_hist->cdata()
            );
        }
        CHECK(cudaDeviceSynchronize());
    }
    end = std::chrono::high_resolution_clock::now();
    std::chrono::duration<double> diff = end - start;
    std::cout << "GPU: " << diff.count() << std::endl;

    {
        dim3 grid(divup(dcloud->cdata().num_vertices, KERNEL_BLOCK_SIZE));
        dim3 block(KERNEL_BLOCK_SIZE);
        evaluate_histogram<<<grid, block>>>(ddir_hist->cdata());
        CHECK(cudaDeviceSynchronize());
    }

    *hdir_hist = *ddir_hist;
#endif

    if (!args.export_cloud.empty()) {
        mve::TriangleMesh::Ptr mesh;
        try {
            mesh = mve::geom::load_ply_mesh(args.proxy_cloud);
        } catch (std::exception& e) {
            std::cerr << "\tCould not load mesh: "<< e.what() << std::endl;
            std::exit(EXIT_FAILURE);
        }

        std::vector<float> & values = mesh->get_vertex_values();
        values.resize(num_vertices);

        cacc::VectorArray<cacc::HOST, cacc::Vec2f>::Data const & dir_hist = hdir_hist->cdata();
        int const stride = dir_hist.pitch / sizeof(cacc::Vec2f);
        #pragma omp parallel for
        for (std::size_t i = 0; i < num_vertices; ++i) {
            cacc::Vec2f mean = dir_hist.data_ptr[(max_cameras - 2) * stride + i];
            cacc::Vec2f eigen = dir_hist.data_ptr[(max_cameras - 1) * stride + i];
            float lambda = std::max(std::abs(eigen[0]), std::abs(eigen[1]));
            values[i] = mean[0] * (10.0f * std::max(0.0f, std::min(lambda, 1.0f / 10.0f)));
        }
        mve::geom::SavePLYOptions opts;
        opts.write_vertex_values = true;
        mve::geom::save_ply_mesh(mesh, args.export_cloud, opts);
    }
}