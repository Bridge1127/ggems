// GGEMS Copyright (C) 2017

/*!
 * \file vox_phan_iort_nav.cuh
 * \brief
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.2
 * \date 23/03/2016
 *
 * v0.2: JB - Change all structs and remove CPU exec
 *
 */

#ifndef VOX_PHAN_IORT_NAV_CUH
#define VOX_PHAN_IORT_NAV_CUH

#include "ggems.cuh"
#include "global.cuh"
#include "ggems_phantom.cuh"
#include "voxelized.cuh"
#include "raytracing.cuh"
#include "vector.cuh"
#include "materials.cuh"
#include "photon.cuh"
#include "photon_navigator.cuh"
#include "image_io.cuh"
#include "dose_calculator.cuh"
#include "cross_sections.cuh"
#include "transport_navigator.cuh"
#include "mu_data.cuh"

// For variance reduction (use in IORT for instance)
#define VRT_ANALOG   0
#define VRT_TLE      1
#define VRT_WOODCOCK 2
#define VRT_SETLE    3

// Mu and Mu_en table used by TLE
struct Mu_MuEn_Data {
    f32* E_bins;      // n
    f32* mu;          // n*k
    f32* mu_en;       // n*k

    ui32 nb_mat;      // k
    ui32 nb_bins;     // n

    f32 E_min;
    f32 E_max;     
};

/*
// History map used by seTLE
struct HistoryMap {
    ui32 *interaction;
    f32 *energy;
};

// COO compression history map used by seTLE
struct COOHistoryMap {
    ui16 *x;
    ui16 *y;
    ui16 *z;
    f32 *energy;
    ui32 *interaction;

    ui32 nb_data;
};
*/

// VoxPhanIORTNav -> VPIN
namespace VPIORTN
{

__host__ __device__ void track_to_out_analog( ParticlesData *particles,
                                              const VoxVolumeData<ui16> *vol,
                                              const MaterialsData *materials,
                                              const PhotonCrossSectionData *photon_CS_table,
                                              const GlobalSimulationParametersData *parameters,
                                              DoseData *dosi,
                                              ui32 part_id );

__host__ __device__ void track_to_out_tle( ParticlesData *particles,
                                           const VoxVolumeData<ui16> *vol,
                                           const MaterialsData *materials,
                                           const PhotonCrossSectionData *photon_CS_table,
                                           const GlobalSimulationParametersData *parameters,
                                           DoseData *dosi,
                                           const Mu_MuEn_Data *mu_table,
                                           ui32 part_id );

/// Experimental

__host__ __device__ void track_to_out_woodcock( ParticlesData *particles,
                                                const VoxVolumeData<ui16> *vol,
                                                const MaterialsData *materials,
                                                const PhotonCrossSectionData *photon_CS_table,
                                                const GlobalSimulationParametersData *parameters,
                                                DoseData *dosi,
                                                f32* mumax_table,
                                                ui32 part_id );
/*
__host__ __device__ void track_to_out_setle(ParticlesData particles,
                                      VoxVolumeData<ui16> vol,
                                      MaterialsTable materials,
                                      PhotonCrossSectionTable photon_CS_table,
                                      GlobalSimulationParametersData parameters,
                                      DoseData dosi,
                                      Mu_MuEn_Table mu_table,
                                      HistoryMap hist_map, ui32 part_id);
*/

/*
__host__ __device__ void track_seTLE(ParticlesData particles,
                                     VoxVolumeData<ui16> vol,
                                     COOHistoryMap coo_hist_map,
                                     DoseData dose,
                                     Mu_MuEn_Table mu_table, ui32 nb_of_rays, f32 edep_th, ui32 id );
*/

//////////////////

__global__ void kernel_device_track_to_in( ParticlesData *particles, f32 xmin, f32 xmax,
                                            f32 ymin, f32 ymax, f32 zmin, f32 zmax , f32 tolerance);

__global__ void kernel_device_track_to_out_analog( ParticlesData *particles,
                                                   const VoxVolumeData<ui16> *vol,
                                                   const MaterialsData *materials,
                                                   const PhotonCrossSectionData *photon_CS_table,
                                                   const GlobalSimulationParametersData *parameters,
                                                   DoseData *dosi );

__global__ void kernel_device_track_to_out_tle( ParticlesData *particles,
                                                const VoxVolumeData<ui16> *vol,
                                                const MaterialsData *materials,
                                                const PhotonCrossSectionData *photon_CS_table,
                                                const GlobalSimulationParametersData *parameters,
                                                DoseData *dosi,
                                                const Mu_MuEn_Data *mu_table );

/// Experimental
__global__ void kernel_device_track_to_out_woodcock( ParticlesData *particles,
                                                     const VoxVolumeData<ui16> *vol,
                                                     const MaterialsData *materials,
                                                     const PhotonCrossSectionData *photon_CS_table,
                                                     const GlobalSimulationParametersData *parameters,
                                                     DoseData *dosi,
                                                     f32* mumax_table );
/*
__global__ void kernel_device_track_to_out_setle( ParticlesData *particles,
                                                 const VoxVolumeData<ui16> *vol,
                                                 const MaterialsData *materials,
                                                 const PhotonCrossSectionData *photon_CS_table,
                                                 const GlobalSimulationParametersData *parameters,
                                                 DoseData *dosi,
                                                 const Mu_MuEn_Table *mu_table,
                                                 HistoryMap *hist_map );

__global__ void kernel_device_seTLE(ParticlesData particles,
                                    VoxVolumeData<ui16> vol,
                                    COOHistoryMap coo_hist_map,
                                    DoseData dosi,
                                    Mu_MuEn_Table mu_table, ui32 nb_of_rays, f32 edep_th );

*/

}

class VoxPhanIORTNav : public GGEMSPhantom
{
public:
    VoxPhanIORTNav();
    ~VoxPhanIORTNav() {}

    // Init
    void initialize( GlobalSimulationParametersData *h_params, GlobalSimulationParametersData *d_params );
    // Tracking from outside to the phantom border
    void track_to_in( ParticlesData *d_particles );
    // Tracking inside the phantom until the phantom border
    void track_to_out( ParticlesData *d_particles );

    void load_phantom_from_mhd( std::string filename, std::string range_mat_name );

    void calculate_dose_to_medium();
    void calculate_dose_to_water();
    
    void write( std::string filename = "dosimetry.mhd" );
    void set_materials( std::string filename );

    void set_vrt( std::string kind );

    ////////////////////////

    void export_density_map( std::string filename );
    void export_materials_map( std::string filename );
//    void export_history_map( std::string filename );

    VoxVolumeData<f32> * get_dose_map();

    AabbData get_bounding_box();

private:

    VoxelizedPhantom m_phantom;
    Materials m_materials;
    CrossSections m_cross_sections;
    DoseCalculator m_dose_calculator;

    Mu_MuEn_Data *mh_mu_table;
    Mu_MuEn_Data *md_mu_table;
//    HistoryMap m_hist_map;
//    COOHistoryMap m_coo_hist_map;

    bool m_check_mandatory();
    void m_init_mu_table();
//    void m_compress_history_map();

    // Get the memory usage
    ui64 m_get_memory_usage();

    f32 m_dosel_size_x, m_dosel_size_y, m_dosel_size_z;
    f32 m_xmin, m_xmax, m_ymin, m_ymax, m_zmin, m_zmax;    

    GlobalSimulationParametersData *mh_params;
    GlobalSimulationParametersData *md_params;

    std::string m_materials_filename;

    ui8 m_flag_vrt;

    // Experimental (Woodcock tracking)
    void m_build_mumax_table();
    f32* m_mumax_table;

//
};

#endif
