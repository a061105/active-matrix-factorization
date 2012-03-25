import numpy as np
cimport numpy as np

cimport cython

DTYPE = np.float
ctypedef np.float_t DTYPE_t

# TODO types
def tripexpect(np.ndarray[DTYPE_t, ndim=1] mean not None,
               np.ndarray[DTYPE_t, ndim=2] cov not None,
               a, b, c):
    '''E[X_a X_b X_c] for N(mean, cov)'''
    return mean[a] * mean[b] * mean[c] + \
            mean[a]*cov[b,c] + mean[b]*cov[a,c] + mean[c]*cov[a,b]

@cython.boundscheck(False)
def quadexpect(np.ndarray[DTYPE_t, ndim=1] mean not None,
               np.ndarray[DTYPE_t, ndim=2] cov not None,
               unsigned int a, unsigned int b, unsigned int c, unsigned int d):
    '''
    E[X_a X_b X_c X_d] for N(mean, cov) and distinct a/b/c/d.

    Assumes that a/b/c/d are within bounds and not negative; will do
    nasty things if this isn't true.
    '''
    # TODO: try method of Kan (2008), see if it's faster?

    cdef DTYPE_t ma = mean[a]
    cdef DTYPE_t mb = mean[b]
    cdef DTYPE_t mc = mean[c]
    cdef DTYPE_t md = mean[d]

    return (
        # product of the means
        ma * mb * mc * md

        # pairs of means times cov of the other two
        + ma * mb * cov[c,d]
        + ma * mc * cov[b,d]
        + ma * md * cov[b,c]
        + mb * mc * cov[a,d]
        + mb * md * cov[a,c]
        + mc * md * cov[a,b]

        # pairs of covariances (Isserlis)
        + cov[a,b] * cov[c,d]
        + cov[a,c] * cov[b,d]
        + cov[a,d] * cov[b,c]
    )

def exp_squared(np.ndarray[DTYPE_t, ndim=1] mean not None,
                np.ndarray[DTYPE_t, ndim=2] cov not None,
                int a, int b):
    '''E[X_a^2 X_b^2] for N(mean, cov)'''
    return 4 * mean[a] * mean[b] * cov[a,b] + 2*cov[a,b]**2 + \
            (mean[a]**2 + cov[a,a]) * (mean[b]**2 + cov[b,b])

def exp_a2bc(np.ndarray[DTYPE_t, ndim=1] mean not None,
             np.ndarray[DTYPE_t, ndim=2] cov not None,
             int a, int b, int c):
    '''E[X_a^2 X_b X_c for N(mean, cov)'''

    cdef DTYPE_t ma = mean[a]
    cdef DTYPE_t mb = mean[b]
    cdef DTYPE_t mc = mean[c]

    return (
        (ma**2 + cov[a,a]) * (mb * mc + cov[b,c])
        + 2 * ma * mc * cov[a,b]
        + 2 * ma * mb * cov[a,c]
        + 2 * cov[a,b] * cov[a,c]
    )

def exp_dotprod_sq(np.ndarray[np.int_t, ndim=2] u not None,
                   np.ndarray[np.int_t, ndim=2] v not None,
                   np.ndarray[DTYPE_t, ndim=1] mean not None,
                   np.ndarray[DTYPE_t, ndim=2] cov not None,
                   int i, int j):
    '''E[ (U_i^T V_j)^2 ]'''
    # TODO: vectorize as much as possible

    cdef float exp = 0
    cdef int latent_dim = u.shape[0]

    for k in range(latent_dim):
        uki = u[k,i]
        vkj = v[k,j]

        exp += exp_squared(mean, cov, uki, vkj)

        for l in range(k+1, latent_dim):
            exp += 2 * quadexpect(mean, cov, uki, vkj, u[l,i], v[l,j])
    return exp


# TODO types
cdef inc_cov_quadexp_grad(np.ndarray[DTYPE_t, ndim=1] mean,
                          np.ndarray[DTYPE_t, ndim=2] cov,
                          float sig,
                          np.ndarray[DTYPE_t, ndim=2] grad_cov,
                          a, b,
                          c, d):
    cdef float inc = (mean[c] * mean[d] + cov[c, d]).sum() / sig
    grad_cov[a, b] += inc
    grad_cov[b, a] += inc


def normal_gradient(apmf not None):
    if apmf.mean is None or apmf.cov is None:
        raise ValueError("run initialize_approx first")

    cdef np.ndarray mean = apmf.mean
    cdef np.ndarray cov = apmf.cov

    cdef np.ndarray u = apmf.u
    cdef np.ndarray v = apmf.v

    cdef np.ndarray us = u.reshape(-1)
    cdef np.ndarray vs = v.reshape(-1)

    cdef float sig = apmf.sigma_sq
    cdef float sig_u = apmf.sigma_u_sq
    cdef float sig_v = apmf.sigma_v_sq

    cdef int uki, vkj
    cdef np.ndarray uli, vlj, u_i, v_j, mu_i, mv_j, inc

    # note that we're actually only differentiating by one triangular half
    # of the covariance matrix, but we make grad_cov the full square anyway
    cdef np.ndarray grad_mean = np.zeros_like(mean)
    cdef np.ndarray grad_cov = np.zeros_like(cov)

    for i, j, rating in apmf.ratings:
        # gradient of sum_k sum_{l>k} E[ U_ki V_kj U_li V_lj ] / sigma^2
        # (doubled because of symmetry, cancels with 2 in denom)
        for k in range(apmf.latent_d-1):
            uki = u[k, i]
            vkj = v[k, j]
            # vectorize out our sums over l
            uli = u[k+1:, i]
            vlj = v[k+1:, j]

            grad_mean[uki] += tripexpect(mean,cov, vkj,uli,vlj).sum() / sig
            grad_mean[vkj] += tripexpect(mean,cov, uki,uli,vlj).sum() / sig
            grad_mean[uli] += tripexpect(mean,cov, uki,vkj,vlj).sum() / sig
            grad_mean[vlj] += tripexpect(mean,cov, uki,vkj,uli).sum() / sig

            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, uki,vkj, uli,vlj)
            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, uki,uli, vkj,vlj)
            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, uki,vlj, vkj,uli)
            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, vkj,uli, uki,vlj)
            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, vkj,vlj, uki,uli)
            inc_cov_quadexp_grad(mean,cov,sig,grad_cov, uli,vlj, uki,vkj)

        # everything else can just be vectorized over k
        u_i = u[:,i]
        v_j = v[:,j]

        mu_i = mean[u_i]
        mv_j = mean[v_j]

        # gradient of \sum_k E[ U_ki^2 V_kj^2 ] / (2 sigma^2)
        grad_mean[u_i] += (2 * mv_j * cov[u_i,v_j]
                           + mu_i * (mv_j**2 + cov[v_j,v_j])) / sig
        grad_mean[v_j] += (2 * mu_i * cov[u_i,v_j]
                           + mv_j * (mu_i**2 + cov[u_i,u_i])) / sig

        grad_cov[u_i,u_i] += (mv_j**2 + cov[v_j,v_j]) / (2*sig)
        grad_cov[v_j,v_j] += (mu_i**2 + cov[u_i,u_i]) / (2*sig)

        inc = 2 * (mu_i * mv_j + cov[u_i,v_j]) / sig
        grad_cov[u_i,v_j] += inc
        grad_cov[v_j,u_i] += inc

        # gradient of - \sum_k Rij E[U_ki V_kj] / sigma^2
        grad_mean[u_i] -= mv_j * (rating / sig)
        grad_mean[v_j] -= mu_i * (rating / sig)

        grad_cov[u_i,v_j] -= rating / sig
        grad_cov[v_j,u_i] -= rating / sig


    # gradient of \sum_i \sum_k E[U_ki^2] / (2 sigma_u^2), same for V
    grad_mean[us] += mean[us] / sig_u
    grad_mean[vs] += mean[vs] / sig_v

    grad_cov[us,us] += 1 / (2 * sig_u)
    grad_cov[vs,vs] += 1 / (2 * sig_v)

    # gradient of ln(|cov|)/2
    # need each cofactor of the matrix divided by its determinant;
    # this is just the transpose of its inverse
    grad_cov += np.linalg.inv(cov).T / 2

    return grad_mean, grad_cov