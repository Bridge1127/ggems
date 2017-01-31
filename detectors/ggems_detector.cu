// GGEMS Copyright (C) 2017

/*!
 * \file ggems_detector.cu
 * \brief
 * \author J. Bert <bert.jul@gmail.com>
 * \version 0.2
 * \date 2 december 2015
 *
 * v0.2: JB - Change all structs and remove CPU exec
 *
 */

#ifndef GGEMSDETECTOR_CU
#define GGEMSDETECTOR_CU

#include "ggems_detector.cuh"

GGEMSDetector::GGEMSDetector()
: m_detector_name( "no_detector" )
{
  ;
}

void GGEMSDetector::set_name(std::string name) {
    m_detector_name = name;
}

void GGEMSDetector::initialize(GlobalSimulationParametersData *h_params) {}

// Move particle to the phantom boundary
void GGEMSDetector::track_to_in(ParticlesData *d_particles) {}

// Track particle within the phantom
void GGEMSDetector::track_to_out(ParticlesData *d_particles) {}

void GGEMSDetector::digitizer(ParticlesData *d_particles) {}

std::string GGEMSDetector::get_name() {
    return m_detector_name;
}

#endif


















